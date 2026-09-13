--- СНИМОК СВОЕГО ДОБРА: сумка и хранилище.
---
--- Чистая часть: ни файлов, ни вызовов игры. Отделено от `market/collect.lua`
--- по тому же правилу, по которому от него отделён `market/parse.lua`: то, что
--- решается без игры, обязано проверяться без игры.
---
--- ⚠ СНИМОК, А НЕ ЖУРНАЛ ИЗМЕНЕНИЙ. Сумка приходит целиком, и хранить разницу
--- значит уметь её склеивать — а склейка врёт, как только один снимок потерялся
--- по дороге. Потеряться он может: доставка идёт очередью через сеть.
---
--- ⚠ ЭТО ЛИЧНОЕ. Состав сумки уходит каналом `me` и виден только хозяину;
--- лут и «Навар» остаются публичными и этим модулем не затрагиваются вовсе.
--- Решение и его обоснование — docs/cdevpowers/specs/2026-08-14-bag-sync-design.md.

local M = {}

M.FILE_VERSION = "0.3.0"

local bagCount = require('market.bagcount').count

-- ⚠ РАЗБОР РЫНКА ГРУЗИТСЯ ЛЕНИВО. Он нужен только снимку из ПАКЕТА
-- (`snapshotOf`), а сборка для игрока читает сумку из разметки
-- (`fullFromCells`) и `market/parse.lua` не везёт вовсе. Прямой `require`
-- наверху уронил бы у неё весь модуль на загрузке.
local parse = setmetatable({}, {
	__index = function(_, k) return require('market.parse')[k] end,
})

--- ЧЕЙ ЭТО СНИМОК: ник персонажа и номер сервера.
---
--- ⚠ БЕЗ НИХ СУМКИ РАЗНЫХ ПЕРСОНАЖЕЙ СМЕШИВАЮТСЯ, И ЭТО НАБЛЮДЕНО 12.09.2026.
--- Сумка на сайте привязана к токену МАШИНЫ, а не к персонажу: на одной машине
--- сессия «Tony_Kawasaki», в игре «Fernendo_Morales», и в журнале лежали
--- снимки обоих вперемешку с Vice City, где своя валюта. Адрес сервера в
--- снимке был, но один сервер живёт под двумя адресами, а номер его — один.
---
--- ⚠ НЕИЗВЕСТНОЕ НЕ ПОДСТАВЛЯЕТСЯ. Пустой ник или номер «0» сайт принял бы за
--- наблюдение; отсутствие поля он честно читает как «не знаем».
local function ownerOf(extra)
	if type(extra) ~= "table" then return nil, nil end
	local nick = extra.nick
	if type(nick) ~= "string" or nick == "" then nick = nil end
	-- Номер сервера целый и положительный (канонические номера Arizona — 1…33,
	-- 200 и 201). Строку-число принимаем: номер мог прийти из разбора JSON.
	local sid = tonumber(extra.sid)
	if not (sid and sid > 0 and sid == math.floor(sid)) then sid = nil end
	return nick, sid
end

--- Свой ник. Вызовы игры ПЕРЕДАЮТСЯ снаружи, и это не ради красоты.
---
--- ⚠ У `sampGetPlayerIdByCharHandle` ДВА ЗНАЧЕНИЯ, И ПЕРВОЕ — ФЛАГ:
--- `bool result, int id`. Взять первое за номер — не ошибка времени выполнения:
--- `sampGetPlayerNickname(true)` приводит аргумент к 1 и отдаёт ник ЧУЖОГО
--- игрока (docs/lessons.md). Сумка уехала бы на сайт под чужим именем, и
--- выглядело бы это наблюдением. Модуль чистый — значит ловушку проверяет
--- тест на хосте с подставными вызовами, а не запуск игры.
---
--- Любой отказ — `nil`: снимок без ника пишется всё равно, ник его не держит.
function M.selfNick(idOf, nickOf, ped)
	if type(idOf) ~= "function" or type(nickOf) ~= "function" then return nil end
	-- `pcall` добавляет своё значение ПЕРЕД двумя значениями функции.
	local okCall, got, id = pcall(idOf, ped)
	if not (okCall and got) or type(id) ~= "number" then return nil end
	local okNick, nick = pcall(nickOf, id)
	if okNick and type(nick) == "string" and nick ~= "" then return nick end
	return nil
end

--- Снимок из ОДНОЙ пачки канала.
---
--- ⚠ ПОЛНОТУ МЫ НЕ УТВЕРЖДАЕМ, И ЭТО ИЗМЕРЕНО, А НЕ ОСТОРОЖНОСТЬ.
---
--- Первая редакция выводила полноту из состава пакета: нет разделов лавки —
--- значит инвентарь открыли один, значит видно всё. Живая доставка 14.08.2026
--- это опровергла: ВСЕ ДВЕНАДЦАТЬ доехавших снимков оказались `cells = 1`, при
--- том что в самой сумке 52 занятые ячейки (снято отладочным портом из
--- разметки). Игрок в это окно инвентарь ОТКРЫВАЛ — `onActiveViewChanged|
--- Inventory` в 22:01:25, — и большой сетки всё равно не пришло.
---
--- Значит через блок `MENU` приезжает не сумка, а ОБНОВЛЕНИЕ ОДНОЙ ЯЧЕЙКИ, и
--- «полного снимка» в этом канале не существует. Правило помечало полным
--- каждое такое обновление, а по полному снимку сайт удаляет пропавшее —
--- то есть первый же заход схлопнул бы состав до одной вещи и стёр пометки
--- «продать». Ровно тот необратимый исход, против которого правило и заводилось.
---
--- Поэтому снимок несёт ФАКТЫ, а не вывод: `solo` — в пачке не было разделов
--- лавки, `cells` — сколько ячеек пришло. Решать по ним будет сайт, и решение
--- можно будет пересмотреть, не переставляя игру. Поля `full` здесь больше нет:
--- утверждение, которого мы не можем подкрепить, лучше не делать вовсе, чем
--- делать и оговаривать.
---
--- `extra` — `{ nick, sid }`, чей снимок (см. `ownerOf`). Необязателен: без
--- него снимок пишется как раньше, просто без этих полей.
function M.snapshotOf(entries, at, srv, extra)
	if type(entries) ~= "table" then return nil end

	local rows, kind, stall = {}, nil, false
	for _, entry in ipairs(entries) do
		local cells, wtype = parse.bagCells(entry)
		if cells then
			kind = kind or parse.kindOf(wtype)
			for _, c in ipairs(cells) do
				local qty, sure = parse.bagCount(c)
				rows[#rows + 1] = {
					slot = c.slot, item = c.item, qty = qty, sure = sure,
					unic = c.unic, color = c.color,
					enchant = c.enchant, strength = c.strength,
					-- Сырое едет РЯДОМ с истолкованием, а не вместо него.
					amount = c.amount, text = c.text, time = c.time,
				}
			end
		elseif type(entry) == "table" and type(entry.data) == "table" then
			if parse.isStallSection(parse.kindOf(tonumber(entry.data.type))) then
				stall = true
			end
		end
	end

	if #rows == 0 then return nil end
	local nick, sid = ownerOf(extra)
	return {
		at = at, srv = srv, nick = nick, sid = sid,
		-- ФАКТ, а не вывод: в этой пачке не было разделов лавки.
		solo = not stall,
		kind = kind, rows = rows, cells = #rows,
	}
end

--- ⚠ ЭКРАНИРУЕТСЯ ТОЛЬКО ТО, ЧТО ЛОМАЕТ СТРОКУ. Подпись ячейки приходит от
--- сервера и содержит что угодно — кавычки в именных вещах встречаются.
--- Незакрытая кавычка делает строку не JSON, и приёмник отбросит её целиком
--- с причиной «не json»: снаружи это выглядит как «сумка не доехала».
--- Снимок из ЯЧЕЕК, прочитанных в РАЗМЕТКЕ окна.
---
--- ⚠ ВОТ ЗДЕСЬ `full` ЗАКОННО, И ЭТО ЕДИНСТВЕННОЕ ТАКОЕ МЕСТО. Пакет приносит
--- по одной ячейке, и утверждать по нему полноту нельзя было. Разметка окна —
--- другое дело: сетка `.inventory-grid__grid--full-size` содержит ВСЕ 72 места
--- сумки разом, и прочитанное из неё и есть состав целиком. Значит по такому
--- снимку сайт вправе удалять пропавшее.
---
--- `cells` — то, что принесла страница: `{ slot, item, text }`. Количество
--- считает `parse.bagCount` здесь, а не в JS: разбор подписи проверен на хосте
--- («88 дней» — срок, «KD» — буквы), и вторая его копия в браузере разошлась бы
--- с первой молча.
---
--- `extra` — `{ nick, sid }`, как у `snapshotOf`. Целому снимку он нужнее всех:
--- именно по нему сайт решает, чья это сумка, и удаляет пропавшее.
function M.fullFromCells(cells, at, srv, extra)
	if type(cells) ~= "table" then return nil end
	local rows = {}
	for _, c in ipairs(cells) do
		local item = tonumber(c.item)
		if item and item > 0 then
			local qty, sure = bagCount(c)
			-- Фон плитки из игры (`--bg` ячейки), `rrggbbaa`. Проверяется ЗДЕСЬ,
			-- а не только в `cefbag`: в JSON он пишется без экранирования.
			local bg = type(c.bg) == 'string' and c.bg:match('^%x%x%x%x%x%x%x%x$') and c.bg:lower() or nil
			rows[#rows + 1] = {
				slot = tonumber(c.slot), item = item,
				qty = qty, sure = sure, text = c.text, bg = bg,
			}
		end
	end
	-- Пустая сетка — тоже ответ, и притом законный: сумку можно опустошить.
	-- Отличается он от «не читали» наличием самого снимка.
	local nick, sid = ownerOf(extra)
	return { at = at, srv = srv, nick = nick, sid = sid, full = true, solo = true,
	         kind = "menu", rows = rows, cells = #rows, from = "разметка" }
end

local function esc(s)
	return (tostring(s)
		:gsub('\\', '\\\\')
		:gsub('"', '\\"')
		:gsub('\n', '\\n')
		:gsub('\r', '\\r')
		:gsub('\t', '\\t'))
end

--- Одна строка JSONL.
---
--- Своя сборка, а не `cjson`: в игре он есть, но тянуть зависимость ради семи
--- полей значит завести её там, где без неё обходятся. Обратный разбор делает
--- сайт, и у него JSON свой.
function M.toJson(snap)
	if type(snap) ~= "table" then return nil end

	local parts = {}
	for _, r in ipairs(snap.rows) do
		local t = { ('{"slot":%d,"item":%d,"qty":%d,"sure":%s')
			:format(r.slot or -1, r.item, r.qty, tostring(r.sure)) }
		if r.unic   then t[#t + 1] = (',"unic":%d'):format(r.unic) end
		if r.color  then t[#t + 1] = (',"color":%d'):format(r.color) end
		-- Наблюдённое без истолкования: имя чужое, значение как пришло.
		if r.enchant  then t[#t + 1] = (',"enchant":%d'):format(r.enchant) end
		if r.strength then t[#t + 1] = (',"strength":%d'):format(r.strength) end
		if r.amount then t[#t + 1] = (',"amount":%d'):format(r.amount) end
		if r.text   then t[#t + 1] = (',"text":"%s"'):format(esc(r.text)) end
		if r.time   then t[#t + 1] = (',"time":%d'):format(r.time) end
		-- Фон плитки: только восемь шестнадцатеричных знаков, иначе не пишем вовсе
		-- (`%s` без экранирования — поэтому проверка стоит и здесь).
		if type(r.bg) == 'string' and r.bg:match('^%x%x%x%x%x%x%x%x$') then
			t[#t + 1] = (',"bg":"%s"'):format(r.bg)
		end
		t[#t + 1] = '}'
		parts[#parts + 1] = table.concat(t)
	end

	-- ⚠ ПОЛЯ `full` В СТРОКЕ НЕТ НАМЕРЕННО. Оно означало «состав целиком» и
	-- давало сайту право удалять пропавшее; наблюдение 14.08.2026 показало, что
	-- целиком сумка в этот канал не приходит вовсе. Пишем наблюдаемое — `solo`
	-- и `cells`, — а выводы делает сайт, где их можно пересмотреть, не трогая
	-- установленную игру.
	-- ⚠ `full` ПИШЕТСЯ ТОЛЬКО КОГДА ОН ПРАВДА ЕСТЬ — то есть у снимка из
	-- разметки. У снимка из пакета его нет и быть не может, и отсутствие поля
	-- здесь означает ровно это, а не «забыли».
	local full = snap.full and ',"full":true' or ''
	local from = snap.from and (',"from":"' .. esc(snap.from) .. '"') or ''

	-- ⚠ ЧЕЙ СНИМОК — ТОЛЬКО ЕСЛИ ИЗВЕСТНО. Проверка повторена здесь, а не только
	-- при сборке снимка: `%d` на строке уронил бы запись целиком, а снимок мог
	-- собрать и не `snapshotOf`.
	local nick, sid = ownerOf(snap)
	local who = (nick and (',"nick":"' .. esc(nick) .. '"') or '')
	         .. (sid and (',"sid":%d'):format(sid) or '')

	return ('{"at":"%s","srv":"%s"%s,"solo":%s%s%s,"kind":"%s","cells":%d,"rows":[%s]}')
		:format(esc(snap.at or ''), esc(snap.srv or ''), who, tostring(snap.solo),
		        full, from, esc(snap.kind or 'menu'), snap.cells,
		        table.concat(parts, ','))
end

return M
