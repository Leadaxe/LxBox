# Фичи

Здесь лежат спецификации **функциональности**: пользовательские сценарии, поведение UI/ядра, ограничения, критерии готовности.

**Имя папки:** `NNN <название с пробелами>` — см. [`../README.md`](../README.md). Внутри — **`spec.md`**.

Примеры содержимого:

- описание экрана подключения и переключения VPN;
- импорт подписки и обновление конфигурации;
- интеграция с sing-box / libbox на Android.

Связывайте с задачами в [`../tasks/`](../tasks/) (зеркальная папка с тем же именем).

## Индекс

| Папка | Кратко |
|-------|--------|
| [`001 mobile stack/`](001%20mobile%20stack/) | Стек: Flutter + нативный VPN + libbox |
| [`002 mvp scope/`](002%20mvp%20scope/) | MVP: один экран — Read / Start–Stop / группы / список + switch + ping (**Android**) |
| [`003 servers tab/`](003%20servers%20tab/) | Блок главного экрана: Clash API, группа, узлы, одиночный ping (минимум) |

Задачи на реализацию и CI: [`../tasks/004 mvp implementation/spec.md`](../tasks/004%20mvp%20implementation/spec.md), [`../tasks/005 cicd github actions/spec.md`](../tasks/005%20cicd%20github%20actions/spec.md).
