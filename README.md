# Todo

A native macOS todo app with a calendar, reminders, a menu bar item, and a local AI assistant powered by [Ollama](https://ollama.com).

- Today, Upcoming, Calendar, and custom lists, with natural-language dates ("Pay rent every month #Personal p1 friday 9am")
- Reminders as macOS notifications, with Complete, Snooze, and Move to Tomorrow actions
- Keeps running in the menu bar after you close the window, and opens at login (switch it off in Settings)
- Assistant that plans your day, breaks tasks into subtasks, and adds tasks and reminders for you

## Build

Needs macOS 15 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh           # builds Todo.app here
./build.sh install   # also installs it to /Applications
```

For AI features, install Ollama and pick a model in Settings > AI. Cloud models (names ending in `:cloud`) send your task text to Ollama's servers.
