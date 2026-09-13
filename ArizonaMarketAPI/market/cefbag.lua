--- КНОПКА «[ASI LAB]» В ОКНЕ ИГРЫ И ЧТЕНИЕ ВСЕЙ СУМКИ ИЗ РАЗМЕТКИ.
---
--- ⚠ ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО — ГЛАВНОЕ В ФАЙЛЕ. Через пакет 220 своя сумка
--- приезжает ПО ОДНОЙ ЯЧЕЙКЕ: наблюдение 14.08.2026 дало 12 снимков из 12 с
--- `cells = 1` при 52 занятых ячейках, причём инвентарь игрок открывал. То есть
--- состава целиком в этом канале нет вовсе, и накопить его дополнениями можно
--- только частично — ровно то, что человек видит на сайте как «четыре предмета».
---
--- Зато состав ЦЕЛИКОМ лежит в разметке окна: сетка `.inventory-grid__grid--
--- full-size`, 72 ячейки, номер предмета в `alt="ID:N"`. Снято отладочным
--- портом в тот же вечер, все 52 позиции. Значит читать надо оттуда.
---
--- ⚠ И ЭТО ЖЕ ДАЁТ ПРАВО УДАЛЯТЬ. Пока состав копился обновлениями, «предмета
--- нет в снимке» не означало «предмета нет в сумке», и удалять было нельзя.
--- Прочитанная целиком сетка — полный снимок, и пропавшее из него пропало.
---
--- ЦЕПОЧКА (та же, что у `asilab-loot.lua`, и это не подражание, а единственный
--- работающий способ: интерфейс — CEF, добавить в него что-то можно только
--- выполнив в нём JavaScript):
---
---   1. `acef.eval` подделывает ВХОДЯЩИЙ пакет 220 подтипа 0x11 — тот самый,
---      которым сервер обычно шлёт `window.executeEvent(...)`. Наружу не уходит
---      ничего: пакет подсовывается своему же клиенту;
---   2. JS вешает кнопку РОДНЫМИ классами интерфейса, чтобы она не выглядела
---      чужой заплатой;
---   3. по нажатию страница шлёт `asilabBag|...` — имя, которого сервер не
---      знает, подтипом 0x12;
---   4. мы ловим его в исходящих и ГЛУШИМ. Доказано 02.08.2026: на погашенную
---      канарейку сервер не ответил ни разу из двух, на непогашенную — оба раза.
---
--- ⚠ ПОДПИСЬ В CP1251. В CEF Arizona идёт однобайтовый текст; UTF-8 здесь не
--- проверен, а проверять на живом интерфейсе игрока дорого.

local M = {}

M.FILE_VERSION = "0.2.0"

--- Имя нашего сообщения. Одно на всё: по нему же идёт глушение, и второе имя
--- означало бы вторую дырку, о которой надо помнить.
M.VERB = 'asilabBag'

--- Подпись кнопки в покое.
M.LABEL = '[ASI LAB] Считать инвентарь'

--- Сколько ячеек кладём в одно сообщение.
---
--- ⚠ ЧИСЛО ИЗ ПРЕДЕЛА КАНАЛА, А НЕ ИЗ ГОЛОВЫ. Сообщение уходит подтипом 0x12
--- одной строкой; 52 ячейки по ~22 байта дают около килобайта, и делить их
--- незачем — но сумка бывает и на 300 позиций, а предел строки нам неизвестен.
--- Сорок ячеек это ~900 байт: заведомо ниже любого разумного предела и заодно
--- даёт полосе прогресса что показывать.
M.CHUNK = 40

-- --- JavaScript ---------------------------------------------------------------
--
-- ⚠ ПОЯСНЕНИЯ К ВНЕДРЯЕМОМУ КОДУ ЖИВУТ ЗДЕСЬ, А НЕ ВНУТРИ СТРОКИ. Код уходит в
-- страницу однобайтовым каналом, где кириллица растёт в 1.74 раза: комментарий
-- в десять строк съедает предел ни за что.

--- Подстановка без `string.format`: в JS полно процентов (`width:100%`), и
--- `%%` на каждый из них — это способ однажды промахнуться молча.
local function fill(tpl, vars)
	return (tpl:gsub('@(%w+)@', function(k) return tostring(vars[k] or '') end))
end

--- Вставить кнопку.
---
--- ⚠ ЯКОРЕМ СЛУЖИТ САМА СЕТКА СУМКИ, А НЕ ОКНО. Первая редакция искала
--- `.shop`, потом окно инвентаря — и кнопка села В ЛАВКУ: у витрины `.shop`
--- есть, и он находился первым. Снаружи это «кнопка не там, где просили», а по
--- сути хуже: она стояла в окне, из которого читать нечего.
---
--- `.inventory-grid__grid--full-size` — это ровно та сетка, которую кнопка и
--- читает. Привязавшись к ней, мы получаем два свойства даром: кнопка есть
--- только там, где есть данные, и появляется она рядом с ними.
---
--- Опрос с шагом 25 мс и до 40 попыток — окно рисуется Svelte не мгновенно, а
--- события «окно готово» у нас нет. Сорок попыток это секунда: дальше ждать
--- бессмысленно, окно не открылось.
M.INJECT = [[
if (!window.__amapiBusy) {
  window.__amapiBusy = true;
  var add = function () {
    var grid = document.querySelector('.inventory-grid__grid--full-size');
    if (!grid) return false;
    var host = grid.parentElement || grid;
    if (document.getElementById('amapi_btn')) return true;
    var bar = document.createElement('div');
    bar.id = 'amapi_btn';
    bar.setAttribute('data-amapi', '1');
    bar.style.cssText = 'width:100%;box-sizing:border-box;padding:8px 14px 12px;';
    var slot = document.createElement('div');
    slot.className = 'shop__button';
    var btn = document.createElement('div');
    btn.className = 'inventory-button inventory-button--default';
    btn.style.cssText = 'cursor:pointer;position:relative;overflow:hidden;';
    var f = document.createElement('div');
    f.id = 'amapi_fill';
    f.style.cssText = 'position:absolute;left:0;top:0;bottom:0;width:0%;' +
      'background:rgba(255,197,61,0.28);transition:width .12s linear;pointer-events:none;';
    var t = document.createElement('div');
    t.className = 'inventory-button__text';
    t.style.cssText = 'position:relative;';
    t.textContent = '@LABEL@';
    btn.appendChild(f); btn.appendChild(t);
    slot.appendChild(btn); bar.appendChild(slot); host.appendChild(bar);
    btn.addEventListener('click', function () {
      if (window.cef && window.cef.SendMessage)
        window.cef.SendMessage('@VERB@|read', 0);
    });
    return true;
  };
  var n = 0, tm = setInterval(function () {
    n++; if (add() || n > 40) { clearInterval(tm); window.__amapiBusy = false; }
  }, 25);
}
]]

function M.injectJs(label, verb)
	return fill(M.INJECT, { LABEL = label or M.LABEL, VERB = verb or M.VERB })
end

--- Подпись и заполнение полосы.
M.SET = [[
(function () {
  var b = document.getElementById('amapi_btn');
  if (!b) return;
  var t = b.querySelector('.inventory-button__text');
  if (t) t.textContent = '@TEXT@';
  var f = document.getElementById('amapi_fill');
  if (f) f.style.width = '@PCT@%';
})();
]]

function M.setJs(text, pct)
	local p = tonumber(pct) or 0
	if p < 0 then p = 0 elseif p > 100 then p = 100 end
	return fill(M.SET, { TEXT = text or '', PCT = math.floor(p) })
end

--- Прочитать ВСЮ сетку сумки из разметки и отослать частями.
---
--- ⚠ ЧИТАЕТСЯ РАЗМЕТКА, А НЕ ПАМЯТЬ СТРАНИЦЫ. Состояние Svelte наружу не
--- выставлено, а разметка — единственное, что видно и что уже проверено:
--- `alt="ID:N"` у картинки, подпись в `.inventory-item__amount`.
---
--- ⚠ ПОДПИСЬ УХОДИТ ДОСЛОВНО. «88 дней», «KD», «1/100» — количеством не
--- являются, и превращать их в числа здесь нельзя: разбор живёт в Lua, где он
--- проверен на хосте. Задача JS — донести увиденное, а не истолковать.
M.READ = [[
(function () {
  var g = document.querySelector('.inventory-grid__grid--full-size');
  if (!g) { window.cef.SendMessage('@VERB@|none', 0); return; }
  var rows = [];
  for (var i = 0; i < g.children.length; i++) {
    var c = g.children[i];
    var im = c.querySelector('img');
    if (!im) continue;
    var id = (im.getAttribute('alt') || '').replace('ID:', '');
    if (!/^[0-9]+$/.test(id)) continue;
    var a = c.querySelector('.inventory-item__amount');
    var lab = a ? a.textContent.trim() : '';
    var bg = '';
    var be = c.querySelector('[style*="--bg"]');
    if (!be && (c.getAttribute('style') || '').indexOf('--bg') >= 0) be = c;
    if (be) {
      var v = be.style.getPropertyValue('--bg');
      var m = v.indexOf('gradient') < 0 && v.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)/);
      if (m) {
        var hx = function (n) { n = Math.max(0, Math.min(255, Math.round(n))); return (n < 16 ? '0' : '') + n.toString(16); };
        bg = hx(+m[1]) + hx(+m[2]) + hx(+m[3]) + hx((m[4] === undefined ? 1 : +m[4]) * 255);
      }
    }
    rows.push(i + ':' + id + ':' + lab.replace(/[|~:]/g, ' ') + ':' + bg);
  }
  window.cef.SendMessage('@VERB@|size|' + rows.length, 0);
  for (var s = 0; s < rows.length; s += @CHUNK@) {
    window.cef.SendMessage('@VERB@|rows|' + s + '|' + rows.slice(s, s + @CHUNK@).join('~'), 0);
  }
  window.cef.SendMessage('@VERB@|done|' + rows.length, 0);
})();
]]

function M.readJs(verb, chunk)
	return fill(M.READ, { VERB = verb or M.VERB, CHUNK = chunk or M.CHUNK })
end

-- --- Разбор ответа страницы ----------------------------------------------------

--- Наше ли это сообщение и о чём оно.
---
--- ⚠ ЭТА ФУНКЦИЯ РЕШАЕТ, ЧТО ГЛУШИТЬ. Ошибись она в сторону «наше» — и мы
--- оборвём настоящее сообщение игры серверу, то есть сломаем игроку интерфейс.
--- Поэтому образец привязан к началу строки и к нашему имени целиком.
function M.parse(text, verb)
	verb = verb or M.VERB
	if type(text) ~= 'string' then return nil end
	local rest = text:match('^' .. verb .. '|(.*)$')
	if not rest then return nil end

	local kind, tail = rest:match('^(%w+)|?(.*)$')
	if kind == 'read' or kind == 'none' then return { kind = kind } end
	if kind == 'size' or kind == 'done' then
		return { kind = kind, n = tonumber(tail) or 0 }
	end
	if kind == 'rows' then
		local from, payload = tail:match('^(%d+)|(.*)$')
		if not from then return { kind = 'rows', from = 0, cells = {} } end
		local cells = {}
		for one in tostring(payload):gmatch('[^~]+') do
			-- `слот:предмет:подпись:фон`. Фон — четвёртым полем и НЕОБЯЗАТЕЛЕН:
			-- страница, внедрённая прежней версией, шлёт три поля, и строка
			-- обязана разбираться как раньше. Двоеточий в подписи нет — их
			-- вычищает сам JS, поэтому граница полей однозначна.
			local slot, item, lab, bg = one:match('^(%d+):(%d+):?([^:]*):?(%x*)$')
			if slot then
				cells[#cells + 1] = {
					slot = tonumber(slot),
					item = tonumber(item),
					-- Пустая подпись остаётся ПУСТОЙ, а не превращается в nil:
					-- «подписи нет» и «поля не было» здесь одно и то же, и
					-- разбор количества (`parse.bagCount`) трактует их одинаково.
					text = lab or '',
					-- Фон плитки, как его рисует игра (`--bg`), `rrggbbaa`; nil —
					-- у вещи своего фона нет (тёмная плитка по умолчанию).
					bg = (bg and #bg == 8) and bg:lower() or nil,
				}
			end
		end
		return { kind = 'rows', from = tonumber(from), cells = cells }
	end
	return { kind = 'unknown', raw = rest }
end

--- Подпись кнопки по ходу чтения. Отдельно от отрисовки, чтобы проверить текст
--- без игры: полоса врёт незаметно, а слова видно.
function M.progress(done, total)
	if not total or total <= 0 then return M.LABEL, 0 end
	local pct = math.floor(done * 100 / total)
	if done >= total then
		return ('[ASI LAB] Считано %d'):format(total), 100
	end
	return ('[ASI LAB] %d из %d'):format(done, total), pct
end

return M
