# §297 — onChange single-dispatch: убрать ручную развязку каскада

**Тип:** cross-cutting refactor (Шаг 4 фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** дедуп РЕАЛИЗОВАН; «не-UI писатели» — открыто · **Размер:** факт. S · **После:** [§294](294-dns-typed-model.md)

> **Уточнение диагноза (при реализации):** «`applyPresetOnChange` руками в 4
> местах» — неточно. Логика **уже** в одной функции `preset_on_change.dart`;
> 4 call-site просто её вызывают (норма для UI-событий rule_enable/dns_enable).
> `settings_screen._applyOnChange` — законно ДРУГОЙ механизм (section-var
> VarValuesModel, source=target в одной модели), не дубль.
>
> **Реальный дубль устранён (коммит ниже):** `preset_on_change._dnsEnableValue`
> дублировал builder-ский `presetDnsEnableVar` (его же docstring это признавал).
> Заменён импортом `presetDnsEnableVar` из `post_steps.dart` (публичная функция,
> цикла импортов нет); дубль-функция удалена. Предикат `dns_enable` теперь один
> на builder+UI+on_change. Тесты `preset_on_change_test` (5, вкл. dns_enable=false)
> зелёные — поведение не изменилось.
>
> **Осталось открытым (не в этом дедупе):** не-UI писатели (Debug generic
> var-PUT, import) не проходят `applyPresetOnChange` вообще — side-effect
> тихо пропускается. Это про API-контур, пересекается с §291-фасадом; решать
> вместе с унификацией внешнего слоя, не точечно здесь.

`applyPresetOnChange` (`preset_on_change.dart:29`) — декларативные side-effect'ы
(§232/§266), пере-вычисляющие производные vars — вызывается **из 4
remember-to-call мест** (routing_screen :464/:597, dns_settings :968, rule
editor). `_dnsEnableValue` — признанный дубль builder-ского
`presetDnsEnableVar`. ~20 экранов импортят onChange-машинерию. **Нет единой
точки диспетчеризации** → забыл вызвать в новом месте = тихий пропуск
side-effect'а (и Debug generic var-PUT / импорты его пропускают всегда).

## Проблема (нарушение §291)

Каскад зависимостей настройки не несётся моделью — он руками развязан по
экранам. Не-UI писатель (Debug, import) молча его не применяет.

## Решение

Свести 4 call-site в один owner каскада (диспетчер), который зовут все писатели
— включая не-UI (Debug var-PUT, import). Де-дублировать `_dnsEnableValue` против
`presetDnsEnableVar`. После §294 (DNS-модель) владелец диспетча становится
очевиден — каскад в основном обслуживает DNS/preset-состояние. `if_engine` уже
даёт единый `makeResolver`/`evalIfScalar` — переиспользовать.

## Файлы

- `lib/services/preset_on_change.dart` (единый диспетчер)
- 4 call-site (routing_screen, dns_settings, rule editor)
- де-дупл `_dnsEnableValue`

## Приёмка

- Один вход применения onChange; не-UI писатели тоже его проходят.
- Нет дубля `_dnsEnableValue`.
- Забыть вызвать в новом месте структурно сложнее (один owner).

## Docs to update

- `docs/ARCHITECTURE.md` — onChange dispatch как единая точка.
