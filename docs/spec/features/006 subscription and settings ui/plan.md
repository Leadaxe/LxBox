# План: 006 — UI подписок и настроек

## Этапы

### 1. Subscription Controller

Создать `lib/controllers/subscription_controller.dart`:
- Состояние: список подписок, статус каждой, общий busy/error
- `addSubscription(String input)` — автоопределение URL vs direct link
- `removeSubscription(int index)`
- `updateAll()` — fetch all → parse → regenerate config
- `generateConfig()` — вызов config builder

### 2. Subscriptions Screen

Создать `lib/screens/subscriptions_screen.dart`:
- AppBar: «Subscriptions» + кнопка «Update all»
- Поле ввода URL + paste + кнопка Add
- Список карточек подписок (URL, nodes count, status)
- Swipe-to-delete
- Прогресс-бар при обновлении

### 3. Settings Screen

Создать `lib/screens/settings_screen.dart`:
- Загрузка vars из wizard template (фильтр по platform + wizard_ui)
- Рендер виджетов по типу (bool → switch, enum → dropdown, text → input, secret → input + random)
- Секция selectable_rules (switch tiles)
- Кнопка Apply внизу

### 4. Обновление Drawer

Модифицировать `lib/screens/home_screen.dart`:
- Добавить пункты Subscriptions и Settings в drawer
- Перегруппировать существующие пункты

### 5. Интеграция

- При добавлении/удалении подписки или изменении настроек → генерация конфига
- Автоматическое обновление состояния главного экрана
- Snackbar с результатом операции

## Зависимости

- Feature 004 (парсер) — для fetch/parse
- Feature 005 (config builder) — для генерации конфига
