--- ГДЕ ЧТО ЛЕЖИТ. Единственный ответ на этот вопрос.
---
--- ⚠ ЗАВЕДЁН ПОТОМУ, ЧТО ПУТЬ СОБИРАЛСЯ СТРОКАМИ В ТРЁХ МЕСТАХ — в отправке, в
--- сборщике и в журнале. Пока мест три, переезд каталога данных означает найти
--- их все и не ошибиться ни в одном; пропущенное место не падает, а тихо пишет
--- в старый каталог, и обнаруживается это по отсутствию данных там, где их
--- ждали.
---
--- ⚠ ДАННЫЕ ПРОДУКТА ЛЕЖАТ ПОД ЕГО ИМЕНЕМ, А НЕ ПОД ИМЕНЕМ ЛАБОРАТОРИИ.
--- До 08.08.2026 всё писалось в `<игра>\ASILab\` — игрок ставил AMAPI, а на
--- диске появлялась папка с чужим именем. Это единственный кусок беспорядка,
--- который видел он сам.
---
--- Обоснование целиком:
--- `docs/cdevpowers/specs/2026-08-08-amapi-collector-migration-design.md`.
---
--- ⚠ ОБРАЩЕНИЕ К ИГРЕ ЗДЕСЬ РОВНО ОДНО И ОНО ПОДМЕНЯЕМО. Склейка путей, разбор
--- разделителей и создание вложенных каталогов — то, что ошибается молча, и
--- проверять это надо на хосте. Прибей мы `getGameDirectory` намертво, единственным
--- способом проверить стал бы запуск игры.

local M = {}

M.FILE_VERSION = "0.1.0"

--- Каталог данных продукта и каталог лаборатории. Второй нужен ровно для одного
--- — разового переезда (`core/migrate.lua`); ничего постоянного оттуда не
--- читается.
M.PRODUCT = 'ArizonaMarketAPI'
M.LEGACY  = 'ASILab'

M.SEP = '\\'

-- --- Чистая часть -------------------------------------------------------------

--- Склейка пути. Лишние разделители схлопываются, косые приводятся к одной.
---
--- ⚠ ПРИВОДЯТСЯ ОБЕ КОСЫЕ. `getGameDirectory` отдаёт путь с обратными, а в коде
--- их пишут по-разному; `io.open` стерпит и то и другое, а вот СРАВНЕНИЕ путей
--- («этот файл мы уже слали») сравнивает строки, и `a/b` с `a\b` окажутся
--- разными файлами при одном и том же содержимом.
function M.join(...)
	local parts = {}
	for i = 1, select('#', ...) do
		local piece = select(i, ...)
		if piece ~= nil and piece ~= '' then
			piece = tostring(piece):gsub('/', M.SEP)
			-- Хвостовой и ведущий разделители снимаются: их добавит склейка.
			piece = piece:gsub('^\\+', ''):gsub('\\+$', '')
			if piece ~= '' then parts[#parts + 1] = piece end
		end
	end
	local out = table.concat(parts, M.SEP)
	-- Корень диска потерял бы двоеточие-слэш: `C:` + `Games` даёт `C:Games`,
	-- а это ДРУГОЙ путь — текущий каталог диска C, а не его корень.
	if out:match('^%a:$') then out = out .. M.SEP end
	return out
end

--- Разложить путь на составляющие. Нужно созданию каталогов: `createDirectory`
--- умеет один уровень, а нам нужен `…\ArizonaMarketAPI\loot`.
function M.parts(path)
	local out = {}
	for piece in tostring(path or ''):gsub('/', M.SEP):gmatch('[^\\]+') do
		out[#out + 1] = piece
	end
	return out
end

-- --- Откуда считаем -----------------------------------------------------------

--- Подмена для проверки на хосте. В игре не зовётся.
local gameDirFn = nil

function M.useGameDir(fn)
	gameDirFn = fn
end

local function base()
	if gameDirFn then return gameDirFn() end
	return getGameDirectory()
end

function M.root()       return M.join(base(), M.PRODUCT) end
function M.legacyRoot() return M.join(base(), M.LEGACY) end

function M.loot(name)    return M.join(M.root(), 'loot', name) end
function M.garbage(name) return M.join(M.root(), 'garbage', name) end
function M.logs(name)    return M.join(M.root(), 'logs', name) end

--- Состояние очереди и токен отправителя. Рядом с журналами, а не в каталоге
--- скрипта: курсор описывает ИХ, и переехать они должны вместе.
function M.state() return M.join(M.root(), 'uplink.json') end
function M.token() return M.join(M.root(), 'uplink-token.txt') end

--- Снимки СВОЕЙ сумки.
---
--- ⚠ В КОРНЕ ПРОДУКТА, А НЕ В `loot/`, И ЭТО НЕ ВКУСОВЩИНА. Всё в `loot/` —
--- наблюдения О МИРЕ: они уходят общим каналом, ложатся в публичный справочник
--- и обратно уже не забираются, потому что на них стоят чужие выводы. Состав
--- сумки принадлежит игроку, уходит каналом `me` и удаляется по его слову.
--- Положи мы его соседом — и первый же обход каталога отправил бы личное
--- туда, откуда его не вернуть.
function M.bag() return M.join(M.root(), 'bag.jsonl') end

--- Отметка о состоявшемся переезде. Лежит в новом корне: старого может уже не
--- быть, а вопрос «переезжали ли» задаётся при каждом запуске.
function M.migrated() return M.join(M.root(), 'migrated.txt') end

-- --- Создание каталогов -------------------------------------------------------

--- Файловые вызовы игры, подменяемые в проверке.
local fs = {
	exists = function(p) return doesDirectoryExist(p) end,
	mkdir  = function(p) return createDirectory(p) end,
}

function M.useFs(t)
	fs = t
end

--- Создать каталог со всеми недостающими родителями.
---
--- ⚠ РАДИ ЭТОГО МОДУЛЬ И ЗАВЕДЁН. `io.open` на запись в несуществующий каталог
--- возвращает `nil` БЕЗ ОШИБКИ — ни исключения, ни строки в журнале. 08.08.2026
--- это дало «токен получен и сохранён» при отсутствующем каталоге: при каждом
--- запуске всё начиналось заново, и снаружи выглядело как исправная работа.
---
--- ⚠ И РОДИТЕЛЕЙ ТОЖЕ. `createDirectory` умеет ОДИН уровень: на свежей
--- установке нет ни `ArizonaMarketAPI`, ни `loot` внутри него, и создание
--- только последнего молча ничего не даст.
---
--- ⚠ СОЗДАЁМ ТОЛЬКО ВНУТРИ КАТАЛОГА ИГРЫ, И ЭТО НАШЛА ПРОВЕРКА, А НЕ РАЗБОР.
--- Первая редакция шла от корня диска и достраивала ВСЮ цепочку. На настоящей
--- машине это безобидно — родители существуют, — но ошибка в склейке пути
--- превращала бы её в создание каталогов где угодно на диске, вплоть до
--- `C:\Games`. Каталог игры мы получили от самой игры, значит он существует;
--- всё, что выше него, — не наше дело.
---
--- Возвращает `true` либо `false, причина` — причина обязана быть, иначе
--- вызывающему нечего записать в журнал.
function M.ensure(dir, under)
	if type(dir) ~= 'string' or dir == '' then return false, 'пустой путь' end
	if fs.exists(dir) then return true end

	under = under or base()
	local top = M.parts(under)
	local all = M.parts(dir)
	if #all == 0 then return false, 'путь не разобрался: ' .. dir end
	if #all <= #top then return false, 'вне каталога игры: ' .. dir end

	for i = 1, #top do
		if all[i]:lower() ~= top[i]:lower() then
			return false, 'вне каталога игры: ' .. dir
		end
	end

	local grown = table.concat(top, M.SEP)
	if grown:match('^%a:$') then grown = grown .. M.SEP end
	for i = #top + 1, #all do
		grown = M.join(grown, all[i])
		if not fs.exists(grown) then
			local ok = pcall(fs.mkdir, grown)
			if not ok or not fs.exists(grown) then
				return false, 'не создать ' .. grown
			end
		end
	end
	return true
end

--- Каталог для файла: создать то, что нужно, и вернуть сам путь.
--- Удобство поверх `ensure`, а не замена: причина отказа не теряется.
function M.ensureFor(path)
	local parts = M.parts(path)
	if #parts < 2 then return false, 'путь без каталога: ' .. tostring(path) end
	table.remove(parts)
	return M.ensure(table.concat(parts, M.SEP))
end

return M
