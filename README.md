# ArizonaMarketAPI

Скрипт для MoonLoader, который подключает игру к сайту **[arizonamarket.fun](https://arizonamarket.fun)**.

Он делает две вещи и больше ничего:

1. `/amapi web` — выдаёт код, чтобы привязать браузер на сайте;
2. когда вы открываете инвентарь, читает сумку из окна и отправляет её на сайт. Там её видит только ваш привязанный браузер — и подсказывает, кому что сейчас сдать дороже.

Скрипт ничего не делает от вашего имени: не покупает, не продаёт и не нажимает кнопок. Пароль, деньги и переписка не отправляются.

## Установка

1. Скачайте [`ArizonaMarketAPI.lua`](https://raw.githubusercontent.com/drshpackz/ArizonaMarketAPI/main/ArizonaMarketAPI.lua) и положите в папку `moonloader` игры.
2. Запустите игру. При первом запуске скрипт сам скачает свои модули (в `moonloader\ArizonaMarketAPI\`) и, если её нет, библиотеку [arizona-events](https://github.com/wojciech941/arizona-events) в `moonloader\lib\`.
3. Наберите в чате `/amapi web` и введите код на [arizonamarket.fun/bind](https://arizonamarket.fun/bind).
4. Откройте инвентарь — он появится на [arizonamarket.fun/quick](https://arizonamarket.fun/quick).

Обновляется скрипт сам: при каждом запуске он сверяет `manifest.json` в этом репозитории.

Нужны MoonLoader и библиотеки `encoding`, `effil`, `requests`, `lfs` — они уже есть в сборке Arizona.

## Условия

Только для некоммерческого использования.

---

Этот репозиторий собирается автоматически (`version` в `manifest.json` — отпечаток содержимого модулей). Правки сюда руками пропадут при следующей сборке.
