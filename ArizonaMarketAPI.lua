script_name('ArizonaMarketAPI')
script_author('arizonamarket.fun')
script_version('1.0.0')
script_url('https://github.com/drshpackz/ArizonaMarketAPI')
script_description('Привязка к arizonamarket.fun и ваш инвентарь на сайте')

-- ARIZONA MARKET — СБОРКА ДЛЯ ИГРОКА. ОДИН ФАЙЛ, ВСЁ ОСТАЛЬНОЕ ОН СТАВИТ САМ.
--
-- Что делает, и больше ничего:
--   1. `/amapi web` — код, чтобы привязать браузер на arizonamarket.fun;
--   2. при открытии инвентаря читает сумку из окна и отправляет её на сайт,
--      где её видит только привязанный браузер.
--
-- ⚠ НИЧЕГО НЕ ДЕЛАЕТ ОТ ИМЕНИ ИГРОКА: не покупает, не продаёт, не нажимает
-- кнопок в интерфейсе игры и не отправляет серверу Arizona ни одного пакета.
-- Своё сообщение страницы (`asilabBag|…`) гасится здесь же — серверу оно не нужно.
--
-- ⚠ УСТАНОВКА. При первом запуске скрипт скачивает опись `manifest.json` из
-- репозитория и раскладывает модули в `moonloader\ArizonaMarketAPI\`, а
-- `arizona-events` — в `moonloader\lib\`, если её там нет (из репозитория её
-- автора, закреплённым коммитом). Дальше при каждом запуске сверяет версию и
-- обновляется сам. Нет сети — работает на уже скачанном.
--
-- Этот файл ПОРОЖДЁН НЕ ГЕНЕРАТОРОМ: он живёт в ASI Lab,
-- `lua\ArizonaMarketAPI\player\ArizonaMarketAPI.lua`, а в репозиторий
-- кладётся как есть. Модули — копии тех же файлов, что работают у нас.

local VERSION = '1.0.0'
local REPO    = 'drshpackz/ArizonaMarketAPI'
local RAW     = 'https://raw.githubusercontent.com/' .. REPO .. '/main/'
local ML      = getWorkingDirectory()
local HOME    = ML .. '\\ArizonaMarketAPI\\'
package.path  = package.path .. ';' .. HOME .. '?.lua'

local COL_INFO = 0xFF7EC8F0
local COL_GOOD = 0xFF9BE86B
local COL_BAD  = 0xFFFF5A5A

-- Чат однобайтовый (CP1251), исходник — UTF-8. `encoding` приходит со сборкой
-- Arizona; нет его — пишем как есть, чем молчать.
local okE, encoding = pcall(require, 'encoding')
local u8 = nil
if okE then
	encoding.default = 'CP1251'
	u8 = encoding.UTF8
end

local function say(line, color)
	local s = '[AMAPI] ' .. tostring(line)
	if u8 then s = u8:decode(s) end
	sampAddChatMessage(s, color or COL_INFO)
end

-- --- Файлы ---------------------------------------------------------------------

local okL, lfs = pcall(require, 'lfs')

local function exists(path)
	local f = io.open(path, 'rb')
	if f then f:close() return true end
	return false
end

local function readAll(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

local function writeAll(path, s)
	local f = io.open(path, 'wb')
	if not f then return false end
	f:write(s)
	f:close()
	return true
end

--- Создать все папки на пути к файлу. `io.open` на запись в несуществующую
--- папку возвращает nil БЕЗ ошибки — и файл «записан», а на диске его нет.
local function ensureDirFor(path)
	local dir = path:match('^(.*)[\\/][^\\/]+$')
	if not dir then return end
	local acc = ''
	for part in dir:gmatch('[^\\/]+') do
		acc = (acc == '') and part or (acc .. '\\' .. part)
		if not acc:match('^%a:$') then
			if okL then pcall(lfs.mkdir, acc)
			elseif not exists(acc .. '\\.') then os.execute('mkdir "' .. acc .. '" 2>nul') end
		end
	end
end

--- Скачать в память. Ждёт внутри потока — звать только из `main` или из
--- `lua_thread`, НИКОГДА из обработчика команды (там ожидание убивает скрипт).
local dlStatus = require('moonloader').download_status
local dlSeq = 0
local function fetch(url)
	-- ⚠ НЕ `os.tmpname()`: на Windows он отдаёт путь в КОРНЕ диска («\s1a4.»),
	-- куда обычному процессу писать нельзя, и скачивание молча не состоялось бы.
	dlSeq = dlSeq + 1
	local tmp = HOME .. ('download-%d.tmp'):format(dlSeq)
	ensureDirFor(tmp)
	local done = false
	downloadUrlToFile(url, tmp, function(_, status)
		if status == dlStatus.STATUSEX_ENDDOWNLOAD then done = true end
	end)
	local deadline = os.clock() + 30
	while not done and os.clock() < deadline do wait(50) end
	local body = readAll(tmp)
	os.remove(tmp)
	return body
end

--- Положить файл атомарно: сперва рядом, потом на место. Полузаписанный модуль
--- уронил бы скрипт при следующем запуске, и починить его было бы нечем.
local function place(path, body)
	ensureDirFor(path)
	local part = path .. '.part'
	if not writeAll(part, body) then return false end
	os.remove(path)
	return os.rename(part, path) ~= nil
end

-- --- Установка и обновление -------------------------------------------------------

--- ⚠ РАЗМЕР СВЕРЯЕТСЯ ВСЕГДА. Страница «404: Not Found» тоже скачивается
--- «успешно», и без сверки она легла бы на место модуля.
local function getChecked(url, size)
	local body = fetch(url)
	if not body or (size and #body ~= size) then return nil end
	return body
end

local function install()
	-- Опись берётся с `main`, и CDN GitHub может отдать её до пяти минут старой
	-- (`max-age=300`, метку в адресе он не учитывает — измерено 13.09.2026).
	-- Это не страшно: файлы качаются по КОММИТУ, который назван в самой описи.
	local raw = fetch(RAW .. 'manifest.json')
	local ok, man = pcall(decodeJson, raw or '')
	if not ok or type(man) ~= 'table' or type(man.files) ~= 'table' then
		return false, 'нет связи с GitHub'
	end

	-- ⚠ АДРЕС ПО КОММИТУ, А НЕ ПО `main`. По `main` CDN отдавал старый файл под
	-- новой описью, размер не сходился, и установка падала до истечения кэша.
	-- Адрес с хешем коммита неизменен: опись и файлы в нём — один снимок.
	local function at(p)
		return 'https://raw.githubusercontent.com/' .. REPO .. '/' .. tostring(man.ref or 'main') .. '/' .. p
	end

	-- Сам установщик устарел — сперва обновляем его и перезапускаемся.
	if man.entry and man.entry.version and man.entry.version ~= VERSION then
		local body = getChecked(at(man.entry.path), man.entry.size)
		local me = thisScript().path
		if body and place(me, body) then
			say(('обновление до %s — перезапускаюсь'):format(man.entry.version), COL_GOOD)
			thisScript():reload()
			return true, 'reload'
		end
	end

	-- При первом запуске файла нет, и разбор пустой строки не имеет права уронить
	-- установку.
	local okH, have = pcall(decodeJson, readAll(HOME .. 'installed.json') or '')
	if not okH or type(have) ~= 'table' then have = {} end
	local fresh = 0
	for _, f in ipairs(man.files) do
		local dest = ML .. '\\' .. f.dest:gsub('/', '\\')
		if have.version ~= man.version or not exists(dest) then
			local body = getChecked(at(f.path), f.size)
			if not body then return false, 'не скачался ' .. f.path end
			if not place(dest, body) then return false, 'не записался ' .. dest end
			fresh = fresh + 1
		end
	end

	-- Чужая библиотека — только если её нет. Свою версию поверх чужой не кладём:
	-- ею пользуются и другие скрипты игрока.
	for _, v in ipairs(man.vendor or {}) do
		if not exists(ML .. '\\' .. v.check:gsub('/', '\\')) then
			for _, f in ipairs(v.files) do
				local body = getChecked(f.url, f.size)
				if not body then return false, 'не скачалась библиотека ' .. v.name end
				place(ML .. '\\' .. f.dest:gsub('/', '\\'), body)
			end
			say(('поставлена библиотека %s'):format(v.name), COL_GOOD)
		end
	end

	if fresh > 0 then
		writeAll(HOME .. 'installed.json', ('{"version":"%s"}'):format(man.version))
		say(('установлено файлов: %d (версия %s)'):format(fresh, man.version), COL_GOOD)
		return true, 'installed'
	end
	return true, 'current'
end

-- --- Работа -------------------------------------------------------------------

function main()
	if not isSampLoaded() then return end
	while not isSampAvailable() do wait(100) end

	local okI, how = install()
	if not okI and not exists(HOME .. 'net\\uplink.lua') then
		say('не удалось установить: ' .. tostring(how) .. '. Проверьте интернет и перезапустите игру.', COL_BAD)
		return
	end
	if how == 'reload' then return end

	-- Чего не хватает из того, что ставит сборка Arizona. Называем, а не молчим:
	-- «отправка молчит» и «нет библиотеки» снаружи неотличимы.
	local missing = {}
	for _, name in ipairs({ 'arizona-events', 'effil', 'requests', 'lfs' }) do
		if not pcall(require, name) then missing[#missing + 1] = name end
	end
	if #missing > 0 then
		say('не хватает библиотек MoonLoader: ' .. table.concat(missing, ', '), COL_BAD)
	end

	local okA, acef = pcall(require, 'arizona-events')
	local okU, uplink = pcall(require, 'net.uplink')
	local okB, cefbag = pcall(require, 'market.cefbag')
	local okG, bag = pcall(require, 'market.bag')
	local okS, sendtext = pcall(require, 'market.sendtext')
	local okP, paths = pcall(require, 'core.paths')
	if not (okU and okB and okG and okS and okP) then
		say('модули не загрузились — удалите папку moonloader\\ArizonaMarketAPI и перезапустите игру', COL_BAD)
		return
	end
	-- Только сумка: лавки сайт берёт из API ArzMarket.
	uplink.DIRS = {}

	local sent = false        -- сказали ли уже в этот заход, что сумка ушла

	sampRegisterChatCommand('amapi', function(arg)
		arg = (arg or ''):lower()
		if arg == 'web' or arg == 'сайт' then
			-- ⚠ ОБРАБОТЧИК НЕ ЖДЁТ: ожидание живёт внутри `bindCode`.
			say('прошу код у сайта…')
			uplink.bindCode(function(code, whereOrWhy)
				if not code then
					say('код не получен: ' .. tostring(whereOrWhy), COL_BAD)
					if not uplink.ready() then say('ключ ещё не получен — он берётся сам, подождите минуту') end
				else
					say(('код: {FFFFFF}%s'):format(code), COL_GOOD)
					say(('введите его на %s/bind — код живёт 5 минут'):format(uplink.SITE))
				end
			end)
		else
			say(uplink.line())
			say('/amapi web — привязать браузер на ' .. uplink.SITE)
		end
	end)

	if not okA then return end

	-- --- Чтение сумки из окна инвентаря ---------------------------------------

	local read = { rows = {}, total = 0, at = nil }
	local lastRead = -1e9

	--- Не чаще раза в три секунды: открытие окна порождает несколько событий.
	local function readSoon()
		local now = localClock()
		if now - lastRead < 3 then return end
		lastRead = now
		pcall(acef.eval, cefbag.readJs())
	end

	local function onBag(msg)
		if msg.kind == 'size' then
			read.rows, read.total, read.at = {}, msg.n, os.date('!%Y-%m-%dT%H:%M:%SZ')
		elseif msg.kind == 'rows' then
			for _, c in ipairs(msg.cells) do read.rows[#read.rows + 1] = c end
		elseif msg.kind == 'done' then
			local srv = nil
			local okS2, ip, port = pcall(sampGetCurrentServerAddress)
			if okS2 and type(ip) == 'string' and tonumber(port) then srv = ip .. ':' .. math.floor(tonumber(port)) end
			local nick = bag.selfNick(sampGetPlayerIdByCharHandle, sampGetPlayerNickname, PLAYER_PED)
			local snap = bag.fullFromCells(read.rows, read.at, srv, { nick = nick })
			if not snap then return end
			local path = paths.bag()
			if not paths.ensureFor(path) then return end
			local f = io.open(path, 'a')
			if not f then return end
			f:write(bag.toJson(snap), '\n')
			f:close()
			pcall(uplink.nudge)
			if not sent then
				sent = true
				say(('инвентарь отправлен на сайт: %d вещей'):format(snap.cells), COL_GOOD)
			end
		end
	end

	acef.onArizonaDisplay = function(packet)
		if not acef.decode(packet) then return end
		if packet.event == 'event.inventory.playerInventory' then readSoon() end
	end

	-- ⚠ САМОЕ ОПАСНОЕ МЕСТО: `false` отсюда ОТМЕНЯЕТ сообщение страницы серверу.
	-- Гасится только своё — `cefbag.parse` привязан к началу строки и к нашему
	-- имени целиком. Всё чужое уходит нетронутым (`nil`).
	acef.onArizonaSend = function(packet)
		local text = sendtext.textOf(packet)
		if not text then return end
		if text:find('onActiveViewChanged|Inventory', 1, true) then readSoon() end
		local msg = cefbag.parse(text)
		if not msg then return end
		pcall(onBag, msg)
		return false
	end

	if how == 'installed' then
		say('готово. Наберите /amapi web, чтобы привязать браузер, и откройте инвентарь.', COL_GOOD)
	end

	while true do
		wait(500)
		pcall(uplink.tick)
	end
end
