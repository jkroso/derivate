# Derivate

A menu bar app that makes your passwords from your full name and your
master password, written in Swift with SwiftUI and AppKit. A shortcut opens it from
any app. You type a site's name, and Enter copies its password.

Derivate makes passwords as [Spectre](https://spectre.app) (formerly Master
Password) does. The same name, master password and site give the same
password in both apps, so you can use them side by side. Spectre calls the
master password your secret.

## Install it

Install Derivate with [Homebrew](https://brew.sh):

```sh
brew install --cask jkroso/tap/derivate
```

You can also download `Derivate-<version>.zip` from the
[latest release](https://github.com/jkroso/derivate/releases/latest). Open
it, and move Derivate.app to your Applications folder.

Derivate needs macOS 14 or later. It runs on Macs with Apple silicon and on
Macs with Intel.

## Use it

1. Press **⌃⌘P** (Ctrl+Cmd+P) in any app, or click the key in the menu bar.
2. Type your master password. Derivate unlocks as soon as it is right,
   without Enter.
3. Type part of a site's name. Use ↑ and ↓ to choose a site. The panel
   shows its password, and the login name you set for it, if any.
4. Press Enter. Derivate copies the password and closes. Paste it with ⌘V.

| Key | What it does |
|---|---|
| Enter | Copies the password of the chosen site |
| Shift+Enter | Copies the login name you set for the chosen site |
| ⌘Enter | Saves the name you typed as a new site and copies its password, even when other sites match |
| ⌘E | Opens the site's details: type, password number, login name, website, security answers |
| ⌘S | Opens your [secrets](#secrets): files and passwords that Derivate keeps for you |
| ⌘L | Locks Derivate |
| ⌘, | Opens the settings |
| Esc | Clears the search, then closes the panel |

Spectre also makes a login name for each site, as it makes passwords.
Derivate does not show it, because few sites use it. To keep your own
login name for a site, open its details (⌘E) and type it in **Login**.

If you type a name that has no site yet, the list shows "New site". Enter
saves that site with your default password type and copies its password.

The shortcut opens the panel in the middle of the screen. This works also
when the menu bar is hidden. A click on the menu bar icon opens the panel
below the icon. Right-click the icon for Import, Export, Settings, Open at
Login and Quit.

> **Note:** the old Master Password app also uses ⌃⌘P. While it runs, it
> gets the shortcut, not Derivate. Quit it and remove it from your login
> items, or record another shortcut in Derivate's settings.

## Locking

Derivate never locks by itself. It forgets your key only when:

- you press ⌘L, or choose **Lock** in the menu bar icon's menu
- Derivate quits, which happens when you log out or restart the Mac

The panel shows the chosen site's password. Press ⌘L before you share your
screen.

## Secrets

Derivate also keeps files and passwords that it cannot make. An example
is a Developer ID certificate that you exported as a `.p12` file, with
the password of that file. Spectre has no place for these, so Spectre
exports do not hold them.

### Add a secret

1. Press **⌘S** in the panel, or click the document icon at the bottom.
   The Secrets screen opens.
2. Drop the file on the panel. Derivate adds a secret with the name of the
   file, and opens it. You can also type a name, press Enter, and click
   **Choose File…**.
3. Type the password of the file in **Password**. Type anything else to
   keep with it in **Notes**.

Derivate keeps an encrypted copy of the file. You can delete the
original. A secret can also hold only a password, or only notes.

### Use a secret

| Key | What it does |
|---|---|
| Enter | Saves the file of the chosen secret where you choose. If it has no file, Enter copies its password. |
| Shift+Enter | Copies the password of the chosen secret |
| ⌘Enter | Opens a new secret with the name you typed, even when other secrets match |
| ⌘E | Opens the details of the secret |
| Esc | Clears the search, then goes back to your sites |
| ⌘S | Goes back to your sites |

Derivate saves the file decrypted. Only your Mac user can read the copy.
To put a certificate back in your keychain, save it, then double-click it
and type its password.

A secret holds one file, of up to 5 MB. AI agents cannot get secrets.

### Keep a copy of your secrets

Derivate cannot make your secrets again from your name and master
password, as it makes your passwords. Back up the folder
`~/Library/Application Support/Derivate/secrets`, for example with Time
Machine. **Export for Spectre** does not include secrets. When you forget
a user in the settings, Derivate deletes their secrets too.

## Import your sites from Spectre

1. In Spectre, export your user. Choose the "Secure" export, which keeps
   stored passwords encrypted.
2. In Derivate, right-click the menu bar icon and choose **Import Spectre
   Export…**. You can also drop the file on the panel.
3. Type the master password you use in Spectre. Derivate checks it
   against the key ID in the export. If the master password is wrong,
   Derivate imports nothing.

Derivate reads these files:

- `.mpjson` files of formats 1, 2 and 3: Master Password 2, the Spectre apps,
  and Spectre's latest code.
- `.mpsites` files of formats 0, 1 and 2: the old Master Password apps.

From each site, Derivate imports the counter, the password type, the
algorithm version (0 to 3), the login name, the stored password, the
security questions, the website and the number of uses.

If you import the same user again, Derivate adds the new sites. For a site
that is in both, it keeps the one you used last.

**Export for Spectre…** writes an `.mpjson` file (format 2) that Spectre 3.1
imports. Stored passwords stay encrypted. Derivate also writes back the
fields of an export that it does not use, so a round trip loses nothing.

## AI agents

Derivate is an MCP server, so that AI agents can get passwords and add
sites. Any agent that runs MCP servers as commands can use it: Claude Code,
Codex, Cursor, Gemini CLI, opencode, Zed, Claude Desktop and others.

### Set it up

1. Open Derivate's settings (⌘,).
2. In **Command**, click **Copy Command**. The command is Derivate's
   executable with the argument `mcp`, for example
   `~/Applications/Derivate.app/Contents/MacOS/Derivate mcp`.
3. Add the command to each agent's MCP settings, as the list below shows.
4. Restart the agent.

The examples use `$DERIVATE` for the path of the executable, without
`mcp`. If you move Derivate, change the path in each agent too.

- **Claude Code:** `claude mcp add --scope user derivate -- $DERIVATE mcp`
- **Gemini CLI:** `gemini mcp add --scope user derivate $DERIVATE mcp`
- **Codex**, in `~/.codex/config.toml`:

  ```toml
  [mcp_servers.derivate]
  command = "$DERIVATE"
  args = ["mcp"]
  ```

- **Cursor** (`~/.cursor/mcp.json`) and **Claude Desktop**
  (`claude_desktop_config.json`), in `"mcpServers"`:

  ```json
  "derivate": { "command": "$DERIVATE", "args": ["mcp"] }
  ```

- **Zed**, in `"context_servers"` in its settings:
  `"derivate": { "command": "$DERIVATE", "args": ["mcp"] }`
- **opencode**, in `"mcp"` in `opencode.json`:
  `"derivate": { "type": "local", "command": ["$DERIVATE", "mcp"] }`

No agent's settings hold a key. `Derivate mcp` reads the key from
Derivate's settings, and passes each message to the app. If the app does
not run, the command opens it.

### What agents can do

| Tool | What it does | Asks you |
|---|---|---|
| `find_sites` | Finds sites by part of their name. It gives names and websites, no passwords. It works while Derivate is locked. | Never |
| `get_password` | Gives a site's password, and the login name you set for it | As the setting says |
| `create_site` | Adds a site and gives its password. Derivate makes the password, or keeps one that the agent gives, encrypted. | As the setting says |

### When Derivate asks you

The **AI agents** setting has four choices:

- **Ask each time** (the default): each `get_password` and `create_site`
  opens the panel. It shows the agent, the folder it works in, and the site.
  Enter allows the request, and Esc refuses it.
- **Ask once per session**: after you allow a request, the same agent
  session gets other passwords without asking until you lock Derivate.
  Each agent session runs its own `Derivate mcp`, and Derivate tells
  sessions apart by that process. An agent that you restart asks again.
- **Never ask**: any agent gets any password while Derivate is unlocked.
- **Off**: Derivate answers no agent.

If Derivate is locked, a request opens the lock screen. When you unlock,
Derivate asks you or answers, as the setting says.

The agent waits up to 2 minutes for your answer. These things refuse a
request: Esc, a click outside the panel, ⌘L, or no answer in 2 minutes.

Enter does nothing for the first 0.6 seconds after a request shows. A key
that you meant for another app then cannot allow it.

> **Note:** a password that an agent gets goes into its conversation. The
> agent sends the conversation to its AI company, and it can keep a copy on
> your Mac. Claude Code, for example, keeps one in `~/.claude/projects`.

### The server in the app

`Derivate mcp` talks to a server that runs inside the app, because only
the running app holds your key.

- Its address is `http://127.0.0.1:39736/mcp`. Only this Mac can connect.
- It answers only requests that send its key, which Derivate keeps in
  `settings.json`. Only your Mac user can read that file.
- It refuses requests from web pages: a request that names another host or
  origin gets "403 Forbidden".
- It speaks MCP 2026-07-28, the version that Claude Code uses, and the
  versions from 2025-03-26 to 2025-11-25. An agent that connects over HTTP,
  not with the command, needs the address and the header
  `Authorization: Bearer <key>`.

## Security

- Derivate never writes your master password or your key to disk. Each user's file holds the same
  data as a Spectre export: site names, counters, types, and stored passwords
  encrypted with your key.
- Each user's secrets are in one file, encrypted with AES-256-GCM. Derivate
  derives the key of that file from your key with HKDF-SHA256, so only your
  name and master password open it. The names of your secrets are encrypted too. If
  someone changes the file, it does not decrypt. Derivate then shows a
  message and does not change the file.
- Derivate marks a copied password as concealed
  (`org.nspasteboard.ConcealedType`). Clipboard managers such as Paste then
  do not keep it. Derivate clears the clipboard after a minute, but only if
  it still holds that password.

## Where the data is

Derivate keeps its data in `~/Library/Application Support/Derivate`:

- `users/<full name>.mpjson`: each user's sites
- `secrets/<full name>.secrets`: each user's secrets, encrypted
- `settings.json`: the shortcut, the clipboard time, the last user, and the
  settings and key for AI agents

On its first run, Derivate moves the data of SpectreBar, its old name, into
this folder. Set `DERIVATE_DIR` to use another folder.

## Build it

Derivate needs macOS 14 or later and Xcode 26 or later (Swift 6.2).

```sh
scripts/build-app.sh             # build/Derivate.app
scripts/build-app.sh --install   # builds it, quits the running copy, puts the new one in ~/Applications and opens it
swift test                       # the algorithm, the export files and the app
scripts/release.sh               # signs and notarises the app, and publishes it on GitHub and in the Homebrew tap
```

Before you run `scripts/release.sh`, change `version` in
`scripts/build-app.sh` and commit it. The comments at the top of
`scripts/release.sh` list what the Mac needs: a Developer ID certificate,
a notary profile and a logged-in `gh`.

`swift test` checks every result in Spectre's published test vectors. To run
the cases of Spectre's own test files as well, set `SPECTRE_TESTS` (see
`Tests/DerivateKitTests`). `DERIVATE_SNAPSHOT=<folder> swift test --filter
snapshot` draws the panel's screens to PNG files. `--filter agentSnapshot`
draws the screens for agents.

## Layout

| Folder or file | What it holds |
|---|---|
| `Sources/DerivateKit` | Spectre's algorithm, versions 0 to 3, its export formats, and the encryption of secrets. It has no UI. |
| `Sources/Derivate/AppDelegate.swift` | The menu bar icon, its menu and the shortcut |
| `Sources/Derivate/Panel.swift` | The floating panel and its blurred background |
| `Sources/Derivate/AppModel.swift`, `Keys.swift` | The app's state: unlocking, the search, copying, import and export, the panel's keys |
| `Sources/Derivate/*View.swift` | The screens: lock, sites, a site's details, secrets, a secret's details, settings |
| `Sources/Derivate/Secrets.swift` | The secrets: the search, adding files, saving them and copying passwords |
| `Sources/Derivate/Store.swift` | The users' files, their secrets files and `settings.json` |
| `Sources/Derivate/Clipboard.swift` | Copies a password to the clipboard with the concealed type |
| `Sources/Derivate/Shortcut.swift` | The global shortcut |
| `Sources/Derivate/AgentServer.swift` | The HTTP server for agents, its key, and its checks of each request |
| `Sources/Derivate/MCP.swift` | MCP's messages: discovery, the list of tools, tool calls |
| `Sources/Derivate/Agents.swift` | The tools, and the requests that wait for you to allow them |
| `Sources/Derivate/PeerProcess.swift` | Finds the process of the agent at the other end of a connection |
| `Sources/Derivate/StdioBridge.swift` | `Derivate mcp`: passes an agent's messages between standard input and output and the app's server |

## Licence

Derivate is free software under the GNU General Public License, version 3.
See [LICENSE](LICENSE). Spectre uses the same licence.

Derivate is not made by Spectre's author, and is not connected with
Spectre. It reads Spectre's files and makes the same passwords, so you can
use both.
