--- Отправка наблюдений на сайт. Диск, поток и сеть.
---
--- Решения — в `net/outbox.lua` (очередь) и `net/wire.lua` (конверт), оба
--- проверяются на хосте. Здесь остаётся то, что без игры не проверить: чтение
--- файлов, отдельный поток и сам обмен.
---
--- ⚠ ЭТОТ МОДУЛЬ ОТПРАВЛЯЕТ ДАННЫЕ НАРУЖУ. Помечено намеренно и здесь, чтобы
--- это не приходилось выяснять из кода (CLAUDE.md, заслон guard-outgoing-traffic).
--- Что именно уходит:
---
---   очередью  — наблюдения О МИРЕ: лавки, их содержимое, цены, мусорки;
---   снимком   — ПРИСУТСТВИЕ: ник, сервер, координаты, деньги на руках.
---
--- ⚠ ВТОРАЯ СТРОКА ПОЯВИЛАСЬ 08.08.2026, И ДО НЕЁ ЗДЕСЬ БЫЛО НАПИСАНО
--- ОБРАТНОЕ — «присутствие не отправляется отсюда никогда». Это перестало быть
--- правдой в тот же день, когда выяснилось, что «где я» нужно самому игроку в
--- его кабинете. Запись поправлена вместе с кодом: комментарий, отставший от
--- поведения, опаснее отсутствующего — на него ссылаются, не перечитывая код.
---
--- Присутствие — ЛИЧНОЕ. Оно ложится в каталог отправителя и отдаётся только
--- его привязанному браузеру; сделки и инвентарь пока не отправляются вовсе.
---
--- ⚠ БЛОКИРУЮЩИЙ ВЫЗОВ УХОДИТ В ОТДЕЛЬНЫЙ ПОТОК, И ЭТО НЕ ОПТИМИЗАЦИЯ.
--- `requests` построен на LuaSocket и ЖДЁТ ответа. Вызванный в цикле
--- MoonLoader, он останавливает игру на всё время обмена — а обмен по чужой
--- сети измеряется секундами. Поток `effil` тут единственный способ: сопрограмм
--- MoonLoader сокет не замечает.
---
--- ⚠ У ПОТОКА `effil` СВОЙ `package.path`. Он не наследует ни путей, ни
--- загруженных модулей: `require 'requests'` внутри него падает, если каталог
--- библиотек не передать аргументом. Снаружи это выглядит как «отправка молчит».

local M = {}

M.FILE_VERSION = "0.4.0"

local outbox = require 'net.outbox'
local wire   = require 'net.wire'

M.SITE      = 'https://arizonamarket.fun'
M.URL       = M.SITE .. '/api/uplink'
M.URL_REG   = M.SITE .. '/api/uplink/register'
M.URL_BIND  = M.SITE .. '/api/bind'
M.URL_WHERE = M.SITE .. '/api/presence'
--- Перекличка: кто сейчас на сервере. Снимок, а не журнал — как и присутствие.
M.URL_ROSTER = M.SITE .. '/api/online'

--- Как часто заглядывать в очередь без повода. Раз в полминуты: журнал пишется
--- при заходе в лавку, а не постоянно, и чаще спрашивать нечего.
M.EVERY = 30

--- Через сколько после открытия лавки слать. Сборщик дописывает файл ПОСЛЕ
--- того, как пришёл заголовок окна, и отправка в тот же кадр застала бы журнал
--- недописанным — ушёл бы кусок без последней лавки, а курсор уехал бы вперёд.
M.AFTER_STALL = 2

-- --- Пути -------------------------------------------------------------------
--
-- ⚠ ПУТИ БЕРУТСЯ У `core.paths`, А НЕ СОБИРАЮТСЯ СТРОКОЙ ЗДЕСЬ. До 08.08.2026
-- такое место было третьим по счёту, и переезд каталога данных означал найти их
-- все; пропущенное не падает, а тихо пишет в старый каталог.
--
-- Там же лежит создание каталога со всеми родителями: `io.open` на запись в
-- несуществующую папку возвращает `nil` БЕЗ ошибки — токен «сохранён»,
-- состояние «записано», а при следующем запуске всё заново. Поймано при первой
-- же установке в чистую игру 08.08.2026.

local paths = require('core.paths')

local function gameRoot()
	return getGameDirectory()
end

local function ensureDir()
	local ok = paths.ensure(paths.root())
	return ok
end

--- Где лежит состояние очереди. Рядом с журналами, а не в каталоге скрипта:
--- курсор описывает ИХ, и переехать они должны вместе.
local function statePath() return paths.state() end

--- Токен. Отдельным файлом, а не в настройках: настройки лежат в репозитории
--- рядом с кодом, а токен — секрет, и попасть в git он не должен.
local function tokenPath() return paths.token() end

-- --- Состояние --------------------------------------------------------------

local state   = nil            -- outbox-состояние, читается один раз
local token   = nil
local busy    = nil            -- дескриптор потока, пока идёт обмен
local sending = nil            -- что именно ушло: имя файла, смещение, длина
local dueAt   = 0
local fails   = 0

M.stat = {
	sent = 0,        -- строк принято сервером
	skipped = 0,     -- строк сервер отбросил
	requests = 0,
	errors = 0,
	rewinds = 0,     -- сколько раз сервер поправил наш курсор
	oversize = 0,    -- строк длиннее предела: не уйдут никогда
	last = nil,      -- последняя новость человеческими словами
	stopped = nil,   -- причина, по которой отправка встала насовсем
}

local function readAll(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

local function loadState()
	if state then return state end
	state = outbox.decode(readAll(statePath()) or "")
	return state
end

local function saveState()
	ensureDir()
	local f = io.open(statePath(), 'wb')
	if not f then
		-- Потеря курсора не теряет данных: при следующем запуске файл уйдёт
		-- заново, а сервер отбросит уже принятое. Но молчать нельзя — иначе
		-- «шлём одно и то же по кругу» выглядит исправной работой.
		M.stat.last = 'курсор не записался в ' .. statePath()
		return
	end
	f:write(outbox.encode(state))
	f:close()
end

local function loadToken()
	if token ~= nil then return token end
	local s = readAll(tokenPath())
	token = s and s:gsub('%s+$', ''):gsub('^%s+', '') or ''
	return token
end

--- Есть ли кому слать. Без токена отправка не «ломается», а НЕ НАЧИНАЕТСЯ, и
--- говорит об этом словами: молчащий канал и канал без ключа — разные новости.
function M.ready()
	local t = loadToken()
	if t == '' then return false, 'токен ещё не получен' end
	return true
end

local function saveToken(t)
	ensureDir()
	local f = io.open(tokenPath(), 'wb')
	if not f then return false end
	f:write(t)
	f:close()
	token = t
	return true
end

-- --- Свой ник ----------------------------------------------------------------
--
-- ⚠ `sampGetPlayerIdByCharHandle` ОТДАЁТ ДВА ЗНАЧЕНИЯ: `bool result, int id`
-- (aidocs/commands/Char-04.md). Взять первое — значит подставить дальше `true`
-- вместо номера, а `sampGetPlayerNickname(true)` НЕ ПАДАЕТ: аргумент
-- приводится к 1, и возвращается ник игрока с номером 1, то есть ЧУЖОЙ. Мы бы
-- зарегистрировались под именем постороннего человека и подписывали бы его
-- ником все свои наблюдения. Тот же разбор — в `asilab-web.lua`.
--
-- Отсюда и проверка `type(id) == 'number'`: `not id` пропустило бы и `false`,
-- и `true`.
local function myNick()
	local okG, state = pcall(sampGetGamestate)
	if not okG or state ~= 3 then return nil, 'не подключён к серверу' end

	local okI, found, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
	if not okI or not found or type(id) ~= 'number' then return nil, 'свой номер неизвестен' end

	local okN, nick = pcall(sampGetPlayerNickname, id)
	if not okN or type(nick) ~= 'string' or nick == '' then return nil, 'ник неизвестен' end
	return nick
end

-- --- Что вообще есть на диске ------------------------------------------------

--- Журналы, которые мы отправляем КАТАЛОГАМИ: путь на диске -> имя потока.
---
--- ⚠ ЛИЧНОЕ КАТАЛОГАМИ НЕ ХОДИТ, И ЭТО ГЛАВНОЕ СВОЙСТВО ЭТОГО СПИСКА. Обход
--- каталога забирает ВСЁ, что в нём лежит с нужным расширением, — значит файл,
--- случайно оказавшийся рядом, уедет на сервер, и никто этого не заметит.
--- Поэтому здесь только `loot` и `garbage`: наблюдения о мире, которые и так
--- публичны. `trades` и `inventory` не отправляются вовсе.
---
--- ⚠ ПОЛЕ МОДУЛЯ, А НЕ ЛОКАЛЬНАЯ, С 13.09.2026. Сборка для игрока (привязка и
--- инвентарь) ставит `uplink.DIRS = {}` — лавки сайт берёт из API ArzMarket, и
--- возить их с машины игрока незачем. Лаборатория шлёт как раньше.
M.DIRS = { loot = 'loot', garbage = 'garbage' }

--- Личные файлы — ПОИМЁННО, по одному, и каждый назван здесь.
---
--- ⚠ ПЕРЕЧИСЛЕНИЕ ЗДЕСЬ УМЕСТНО РОВНО ПОТОМУ, ПОЧЕМУ ОНО НЕУМЕСТНО В РАЗБОРЕ.
--- Обычно список имён — плохая замена измерению: он молча ломается на первом
--- незнакомом случае. Здесь незнакомый случай и есть то, что надо остановить:
--- новый личный файл обязан попасть наружу СОЗНАТЕЛЬНО, строкой в этом списке,
--- а не потому, что оказался в каталоге.
---
--- Сервер это и проверяет со своей стороны: поток `me.bag` требует токена с
--- правом на личный канал, а самовыдаче он закрыт (`app/api/uplink/route.ts`).
--- Две проверки с разных сторон — не дублирование: клиент можно переписать,
--- сервер нельзя.
local function soloFiles()
	return { { disk = paths.bag(), name = 'bag.jsonl' } }
end

local function files()
	local lfsOk, lfs = pcall(require, 'lfs')
	if not lfsOk then return {}, 'нет lfs' end

	local out = {}

	-- ⚠ ЛИЧНЫЕ ИДУТ ПЕРВЫМИ И БЕЗ ОБХОДА КАТАЛОГА. Размер спрашивается у самого
	-- файла: нет файла — нет и строки, а не пустая запись с нулём. Пустой файл
	-- пропускается по тому же правилу, что и в обходе ниже: слать нечего.
	for _, s in ipairs(soloFiles()) do
		local size = lfs.attributes(s.disk, 'size')
		if size and size > 0 then
			out[#out + 1] = { name = s.name, disk = s.disk, size = size }
		end
	end
	for dir, prefix in pairs(M.DIRS or {}) do
		local path = paths.join(paths.root(), dir)
		local okDir = pcall(function()
			for name in lfs.dir(path) do
				if name:sub(-6) == '.jsonl' then
					local disk = paths.join(path, name)
					local size = lfs.attributes(disk, 'size')
					if size and size > 0 then
						out[#out + 1] = {
							-- Имя для сервера — с ПРЯМОЙ косой и без корня: по нему
							-- ведётся курсор, и он обязан быть одинаковым у всех
							-- игроков независимо от того, куда поставлена игра.
							name = prefix .. '/' .. name,
							disk = disk,
							size = size,
						}
					end
				end
			end
		end)
		-- Каталога может не быть вовсе: игрок ещё не открывал ни лавки, ни бака.
		-- Это не ошибка, и в журнал такое писать незачем.
		local _ = okDir
	end
	return out
end

-- --- Один заход --------------------------------------------------------------

local function headOf(disk)
	local f = io.open(disk, 'rb')
	if not f then return nil end
	local head = f:read(outbox.HEAD_BYTES) or ''
	f:close()
	return outbox.fingerprint(head)
end

local function tailOf(disk, from, want)
	local f = io.open(disk, 'rb')
	if not f then return nil end
	local okSeek = f:seek('set', from)
	if not okSeek then f:close() return nil end
	local s = f:read(want) or ''
	f:close()
	return s
end

--- Файлы, отложенные после нескольких неудач подряд.
---
--- ⚠ ЗАВЕДЕНО ПОТОМУ, ЧТО ОДИН НЕГОДНЫЙ ФАЙЛ КЛАЛ ВЕСЬ КАНАЛ. Очередь берёт
--- файлы ПО ИМЕНИ и возвращает первый недосланный; спотыкаясь на нём каждый
--- круг, она никогда не доходила до остальных. 15.08.2026 таким оказался
--- `garbage/bins.jsonl`, записанный в CP1251 вместо UTF-8: 21 КБ записей о
--- лавках и 130 КБ снимков не уезжали пять часов, а снаружи это выглядело как
--- «синхронизация не работает».
---
--- Откладывание ВРЕМЕННОЕ: список живёт до перезагрузки скрипта, потому что
--- файл могут починить, и вечная опала превратила бы защиту в потерю данных.
local skip = {}
local badRuns = {}

--- После скольких неудач подряд файл откладывается. Три — чтобы разовая сетевая
--- неурядица не уводила файл из очереди, а устойчивая негодность уводила.
M.BAD_LIMIT = 3

--- Отметить исход отправки файла. Возвращает `true`, если файл только что
--- отложен, — вызывающему это нужно, чтобы сказать об этом ОДИН раз.
function M.noteFile(name, ok)
	if not name then return false end
	if ok then
		badRuns[name] = nil
		return false
	end
	badRuns[name] = (badRuns[name] or 0) + 1
	if badRuns[name] >= M.BAD_LIMIT and not skip[name] then
		skip[name] = true
		M.stat.skippedFiles = (M.stat.skippedFiles or 0) + 1
		M.stat.last = ('файл отложен после %d неудач: %s'):format(badRuns[name], name)
		return true
	end
	return false
end

--- Какие файлы отложены. Для показа человеку: молчаливо отложенный файл — это
--- потерянные данные, о которых никто не узнает.
function M.parked()
	local out = {}
	for name in pairs(skip) do out[#out + 1] = name end
	table.sort(out)
	return out
end

--- Готовит следующий кусок. Возвращает таблицу для отправки или nil.
local function nextChunk()
	local st = loadState()
	local list = files()

	local plan = outbox.plan(st, list, skip)
	if not plan then return nil end

	local disk
	for _, f in ipairs(list) do if f.name == plan.name then disk = f.disk end end
	if not disk then return nil end

	local head = headOf(disk)
	if not head then return nil end

	-- Файл подменён или обрезан — курсор в ноль. Отпечаток отвечает на вопрос
	-- «тот ли это файл», на который смещение ответить не может.
	if plan.shrunk or not outbox.sameFile(st, plan.name, head) then
		state = outbox.reset(st, plan.name, head)
		saveState()
		plan.from = 0
	end

	local tail = tailOf(disk, plan.from, outbox.MAX_BYTES)
	if not tail or tail == '' then return nil end

	local cut = outbox.cut(tail, plan.from)
	if cut.oversize then
		-- Строка длиннее предела не уйдёт никогда. Молчать о ней нельзя: очередь
		-- встанет, и снаружи это будет выглядеть как «отправка работает».
		--
		-- ⚠ И ФАЙЛ ОТКЛАДЫВАЕТСЯ СРАЗУ, БЕЗ ТРЁХ ПОПЫТОК. «Не влезет никогда» —
		-- это не неудача связи, а свойство файла: повторять его бессмысленно, а
		-- держать им очередь — вредно.
		M.stat.oversize = M.stat.oversize + 1
		M.stat.last = 'строка длиннее предела в ' .. plan.name
		skip[plan.name] = true
		M.stat.skippedFiles = (M.stat.skippedFiles or 0) + 1
		return nil
	end
	if cut.chunk == '' then return nil end

	return { name = plan.name, from = plan.from, head = head,
	         chunk = cut.chunk, upto = cut.upto, lines = cut.lines }
end

-- --- Поток -------------------------------------------------------------------

--- Тело потока. Всё, что ему нужно, приходит АРГУМЕНТАМИ: у него свой
--- интерпретатор, и ни путей, ни модулей отсюда он не видит.
local function worker()
	local effil = require 'effil'
	return effil.thread(function(libDir, url, tok, body)
		package.path  = package.path  .. ';' .. libDir .. '\\?.lua;' .. libDir .. '\\?\\init.lua'
		package.cpath = package.cpath .. ';' .. libDir .. '\\?.dll;' .. libDir .. '\\?\\core.dll'

		local okR, requests = pcall(require, 'requests')
		if not okR then return 0, 'нет requests: ' .. tostring(requests) end

		local okP, r = pcall(requests.post, url, {
			data = body,
			headers = {
				['Content-Type']  = 'application/json',
				['Authorization'] = 'Bearer ' .. tok,
			},
			timeout = 20,
		})
		if not okP then return 0, tostring(r) end
		return tonumber(r.status_code) or 0, tostring(r.text or '')
	end)
end

--- Запрос токена. Тот же поток, тот же обмен — отличается только тем, что
--- отправлять нечего и заголовок с ключом не нужен.
---
--- ⚠ ЭТО НЕ «ВХОД» И НЕ РЕГИСТРАЦИЯ ИГРОКА. Сервер не может проверить, что мы
--- в игре, и не притворяется, что может: токен опознаёт ОТПРАВИТЕЛЯ, чтобы его
--- наблюдения считались одним голосом, а не сотней, и чтобы виноватого можно
--- было отозвать. Пароля и учётной записи здесь нет и не будет.
local function startRegister()
	local nick, why = myNick()
	if not nick then
		M.stat.last = 'самовыдача ждёт: ' .. tostring(why)
		return false
	end

	local okT, run = pcall(worker)
	if not okT then
		M.stat.stopped = 'нет effil: ' .. tostring(run)
		return false
	end
	local okS, h = pcall(run, gameRoot() .. '\\moonloader\\lib', M.URL_REG, '',
	                     wire.registration(nick, nil))
	if not okS then
		M.stat.stopped = 'поток не запустился: ' .. tostring(h)
		return false
	end
	busy, sending = h, { register = true, nick = nick }
	M.stat.requests = M.stat.requests + 1
	return true
end

local function start(chunk)
	local okT, run = pcall(worker)
	if not okT then
		M.stat.stopped = 'нет effil: ' .. tostring(run)
		return false
	end
	local body = wire.envelope(chunk.name, chunk.from, chunk.head, chunk.chunk)
	local okS, h = pcall(run, gameRoot() .. '\\moonloader\\lib', M.URL, loadToken(), body)
	if not okS then
		M.stat.stopped = 'поток не запустился: ' .. tostring(h)
		return false
	end
	busy, sending = h, chunk
	M.stat.requests = M.stat.requests + 1
	return true
end

local function finish()
	local okG, code, text = pcall(function() return busy:get() end)
	busy = nil
	local chunk = sending
	sending = nil
	if not okG then
		fails = fails + 1
		M.stat.errors = M.stat.errors + 1
		M.stat.last = 'поток не отдал ответ'
		dueAt = os.clock() + outbox.backoff(fails)
		return
	end

	local rep = wire.reply(text)
	local what = wire.verdict(code, rep)

	-- Ответ самовыдачи разбирается отдельно: там нет ни курсора, ни строк.
	if chunk.register then
		if what == 'ok' and rep.token and rep.token ~= '' then
			fails = 0
			if saveToken(rep.token) then
				M.stat.last = ('токен получен, отправитель %s'):format(tostring(rep.id or '?'))
				dueAt = 0
			else
				-- Токен есть, а записать некуда: при следующем запуске всё
				-- начнётся заново и выдастся ВТОРОЙ токен. Молчать нельзя —
				-- снаружи это выглядит как исправная работа.
				M.stat.stopped = 'токен получен, но не записался в ' .. tokenPath()
			end
		elseif what == 'stop' then
			M.stat.stopped = ('самовыдача отказала: %d %s'):format(code, rep.error or '')
		else
			fails = fails + 1
			M.stat.last = ('самовыдача: %d, повтор через %d с'):format(code, outbox.backoff(fails))
			dueAt = os.clock() + outbox.backoff(fails)
		end
		return
	end

	if what == 'ok' then
		fails = 0
		M.noteFile(chunk.name, true)
		state = outbox.ack(state, chunk.name, rep.upto or chunk.upto, chunk.lines, chunk.head)
		saveState()
		M.stat.sent = M.stat.sent + (rep.accepted or 0)
		M.stat.skipped = M.stat.skipped + (rep.skipped or 0)
		M.stat.last = ('%s: принято %d'):format(chunk.name, rep.accepted or 0)

		-- ⚠ ПРИНЯТО НОЛЬ ИЗ N — ЭТО ПОЛОМКА, А НЕ ОТТЕНОК УСПЕХА, и молчать о
		-- ней нельзя. Ровно так час 08.08.2026 уходили находки с пустым полем
		-- времени: код 200, курсор двигался, «отброшено» росло в сводке, куда
		-- никто не смотрел.
		local bad = wire.rejection(rep)
		if bad then
			M.stat.allRejected = (M.stat.allRejected or 0) + 1
			M.stat.last = ('%s: %s'):format(chunk.name, bad)
			if M.onTrouble then pcall(M.onTrouble, M.stat.last) end
		end
		-- Есть что слать дальше — шлём сразу, не дожидаясь получаса.
		dueAt = 0
	elseif what == 'rewind' then
		-- Сервер знает лучше: он ведёт курсор. Спорить с ним нечем — у нас нет
		-- ответа на вопрос, что у него уже лежит.
		fails = 0
		M.stat.rewinds = M.stat.rewinds + 1
		state = outbox.reset(state, chunk.name, chunk.head)
		state = outbox.ack(state, chunk.name, rep.expect or 0, 0, chunk.head)
		saveState()
		M.stat.last = ('%s: курсор поправлен на %d'):format(chunk.name, rep.expect or 0)
		dueAt = 0
	elseif what == 'stop' then
		M.stat.errors = M.stat.errors + 1
		M.stat.stopped = ('%d %s'):format(code, rep.error or 'отказ')
		M.stat.last = M.stat.stopped
	else
		fails = fails + 1
		M.stat.errors = M.stat.errors + 1
		M.stat.last = ('%d, повтор через %d с'):format(code, outbox.backoff(fails))
		dueAt = os.clock() + outbox.backoff(fails)

		-- ⚠ НЕУДАЧА ЗАПИСЫВАЕТСЯ ЗА КОНКРЕТНЫМ ФАЙЛОМ, и после трёх подряд он
		-- откладывается. Иначе один негодный файл держит очередь вечно: она
		-- берёт файлы по имени и возвращает ПЕРВЫЙ недосланный, то есть
		-- спотыкается об него каждый круг и до остальных не доходит никогда.
		--
		-- ⚠⚠ НО ТОЛЬКО ЕСЛИ ВИНОВАТ ФАЙЛ. Квота отправителя (429) и обрыв связи
		-- — причины ОБЩИЕ: следующий в очереди получил бы то же самое. Записав
		-- их за файлом, мы откладываем невиновного — и ровно так справочник
		-- баков не уезжал сутки при исправном обмене по остальным потокам
		-- (разбор — `wire.blameFile`).
		if wire.blameFile(code) then
			if M.noteFile(chunk.name, false) and M.onTrouble then
				pcall(M.onTrouble, M.stat.last)
			end
		end
	end
end

-- --- Наружу -------------------------------------------------------------------

--- Зовётся из главного цикла. Ничего не ждёт: либо забирает готовый ответ,
--- либо начинает следующий обмен, либо возвращается сразу.
function M.tick()
	if busy then
		local okS, s = pcall(function() return busy:status() end)
		if not okS then busy = nil sending = nil return end
		if s == 'running' then return end
		finish()
		return
	end

	if M.stat.stopped then return end
	if os.clock() < dueAt then return end

	-- Токена нет — просим сами. Это первое, что делает канал у нового игрока, и
	-- ждать от человека тут нечего: ключ не удостоверяет его, а опознаёт нас.
	if not M.ready() then
		if not startRegister() then dueAt = os.clock() + M.EVERY end
		return
	end

	local okC, chunk = pcall(nextChunk)
	if not okC then
		M.stat.errors = M.stat.errors + 1
		M.stat.last = 'не собрался кусок: ' .. tostring(chunk)
		dueAt = os.clock() + M.EVERY
		return
	end
	if not chunk then
		dueAt = os.clock() + M.EVERY
		return
	end
	if not start(chunk) then dueAt = os.clock() + M.EVERY end
end

--- «Лавка открылась». Не шлёт сразу: сборщик дописывает журнал после заголовка
--- окна, и отправка в тот же кадр застала бы его недописанным.
function M.nudge()
	if M.stat.stopped then return end
	dueAt = os.clock() + M.AFTER_STALL
end

--- Отправить тело по адресу и позвать `done(ok, причина)`. Общая дверь наружу.
---
--- ⚠ ЗАВЕДЕНА, ЧТОБЫ НЕ БЫЛО ВТОРОЙ. Присутствию нужен тот же обмен: поток
--- `effil`, тот же токен, тот же разбор ответа. Скопируй мы это в соседний
--- модуль — получили бы две правды об одном обмене, и чинить их пришлось бы
--- порознь. Здесь уже есть и поток, и токен, и знание про чужие библиотеки.
function M.post(url, body, done)
	done = done or function() end
	if not M.ready() then done(false, 'токен ещё не получен') return end

	local okT, run = pcall(worker)
	if not okT then done(false, 'нет effil: ' .. tostring(run)) return end

	local okS, h = pcall(run, gameRoot() .. '\\moonloader\\lib', url, loadToken(), body)
	if not okS then done(false, 'поток не запустился: ' .. tostring(h)) return end

	lua_thread.create(function()
		local until_ = os.clock() + 25
		while h:status() == 'running' do
			if os.clock() > until_ then done(false, 'сайт не ответил') return end
			wait(50)
		end
		local okG, code, text = pcall(function() return h:get() end)
		if not okG then done(false, 'поток не отдал ответ') return end
		local rep = wire.reply(text)
		if wire.verdict(code, rep) ~= 'ok' then
			done(false, ('%d %s'):format(code, rep.error or 'отказ'))
			return
		end
		done(true, text)
	end)
end

-- --- Привязка браузера ----------------------------------------------------------

--- Попросить у сайта код для привязки браузера. Ответ приходит В ОБРАТНЫЙ
--- ВЫЗОВ: `done(код, где)` при удаче, `done(nil, причина)` при отказе.
---
--- ⚠ ОБРАТНЫЙ ВЫЗОВ, А НЕ ВОЗВРАТ, И ЭТО ОПЛАЧЕНО ПАДЕНИЕМ 08.08.2026.
--- Первая редакция ждала ответа прямо в функции и возвращала код. Позвали её из
--- обработчика чат-команды — и скрипт УМЕР:
---
---     uplink.lua:481: attempt to yield across C-call boundary
---     ArizonaMarketAPI: Script died due to an error.
---
--- Обработчик команды вызывается ИЗ C, и уступить управление оттуда нельзя:
--- `wait` там не «медленно», а смертельно. Снаружи это выглядит как «команда
--- крашит» — без единого намёка на то, что дело в ожидании.
---
--- Поэтому ожидание живёт ВНУТРИ, в собственном потоке, и ошибиться вызывающему
--- больше нечем: функция не ждёт вовсе и возвращает управление немедленно.
---
--- ⚠ ТОКЕН ЧЕЛОВЕКУ НЕ ПОКАЗЫВАЕТСЯ И В БРАУЗЕР НЕ ПОПАДАЕТ. Он подписывает
--- наблюдения; браузер получит свой секрет, только на чтение. Смешай их —
--- утечка cookie дала бы право писать от чужого имени.
function M.bindCode(done)
	done = done or function() end

	if not M.ready() then done(nil, 'токен ещё не получен') return end

	local okT, run = pcall(worker)
	if not okT then done(nil, 'нет effil: ' .. tostring(run)) return end

	local okS, h = pcall(run, gameRoot() .. '\\moonloader\\lib', M.URL_BIND, loadToken(), '{}')
	if not okS then done(nil, 'поток не запустился: ' .. tostring(h)) return end

	lua_thread.create(function()
		-- Предел тот же, что у обмена: молчит сайт дольше — человеку надо
		-- сказать об этом, а не держать его в неизвестности.
		local until_ = os.clock() + 25
		while h:status() == 'running' do
			if os.clock() > until_ then done(nil, 'сайт не ответил') return end
			wait(50)
		end

		local okG, code, text = pcall(function() return h:get() end)
		if not okG then done(nil, 'поток не отдал ответ') return end

		local rep = wire.reply(text)
		if wire.verdict(code, rep) ~= 'ok' then
			done(nil, ('%d %s'):format(code, rep.error or 'отказ'))
			return
		end
		local six = tostring(text):match('"code"%s*:%s*"(%d+)"')
		if not six then done(nil, 'ответ без кода') return end
		done(six, tostring(text):match('"where"%s*:%s*"([^"]*)"') or M.SITE)
	end)
end

--- Сколько ещё не отправлено. Отвечает на вопрос, которого не задаёт «сколько
--- отправлено»: включённая отправка и ДОГНАВШАЯ отправка — разные вещи.
function M.pending()
	local okP, left = pcall(function() return outbox.pending(loadState(), files()) end)
	if not okP then return { bytes = 0, files = 0 } end
	return left
end

--- Короткая строка для показа человеку.
function M.line()
	if M.stat.stopped then return 'AMAPI: отправка встала — ' .. M.stat.stopped end
	if not M.ready() then return 'AMAPI: получаю токен…' end
	if busy then return 'AMAPI: отправка…' end
	local left = M.pending()
	if left.bytes > 0 then
		return ('AMAPI: осталось %d КБ в %d файлах'):format(math.ceil(left.bytes / 1024), left.files)
	end
	return ('AMAPI: отправлено %d, отброшено %d'):format(M.stat.sent, M.stat.skipped)
end

return M
