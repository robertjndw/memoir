# AI assistants (MCP)

Memoir runs an [MCP](https://modelcontextprotocol.io) server that lets Claude
Code, Claude Desktop and other MCP clients search and read your meetings, for
example to look up what was decided last week or to draft a follow-up email
from a call.

The server is off by default. Assistants can read meetings, summaries and
transcripts, but they can't record, change or delete anything.

Note that this is the only part of Memoir that sends meeting content off your
Mac: whatever an assistant reads goes to its provider, like anything else you
paste into a chat with it.

## Setup

Turn on "Allow AI assistants to read your meetings" in Memoir Settings > AI
Assistants. The same pane has the command and config snippet below with the
path of your copy of Memoir filled in, and a Copy button.

### Claude Code

```sh
claude mcp add --scope user memoir -- /Applications/Memoir.app/Contents/MacOS/memoir-mcp
```

### Claude Desktop

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json`
(next to any `mcpServers` you already have) and restart Claude Desktop:

```json
{
  "mcpServers" : {
    "memoir" : {
      "command" : "/Applications/Memoir.app/Contents/MacOS/memoir-mcp"
    }
  }
}
```

### Other clients

Any client that supports stdio servers should work. The command is
`/Applications/Memoir.app/Contents/MacOS/memoir-mcp`, without arguments.

Settings > AI Assistants shows whether the server is running and which clients
are connected.

## Tools

| Tool | What it does |
| --- | --- |
| `list_meetings` | Lists meetings, newest first, with id, title, date, duration, attendees and a one-line overview. Optional: `from` and `to` (`YYYY-MM-DD`) and `limit`. |
| `search_meetings` | Searches titles, summaries and transcripts for `query` and returns the best matches with the relevant transcript passages. Uses keyword and semantic search. Optional: `from` and `to`. |
| `get_meeting` | Returns a meeting by `id` with its summary and action items. Pass `query` to also get the matching transcript passages, or `include_transcript` for the whole transcript (cut off if it's very long). |

Transcript passages look like `[mm:ss] Speaker: text`, with "You" or "Others"
as the speaker.

## How it works

The server itself runs in the app. While the setting is on, Memoir listens on
a Unix socket at `~/Library/Application Support/Memoir/mcp.sock`.

MCP clients start `memoir-mcp`, a helper in the app bundle that just passes
data between stdin/stdout and the socket (the same idea as `xcrun mcpbridge`).
It launches Memoir in the background if it isn't running. If it can't reach
Memoir, the helper answers every request with an error instead of exiting and
leaving the client with a server that failed to start. It tries again on each
request, so once the setting is on or Memoir has finished starting, the next
request goes through.

## Troubleshooting

"Memoir access for AI assistants is turned off": Memoir is running but isn't
serving the socket. Turn the setting on, then send the request again.

"Memoir could not be reached": Memoir isn't running, is still starting, or
didn't open the socket in time. Try again in a moment, and check the setting
if it keeps happening.

The client can't find `memoir-mcp`: the path depends on where Memoir is
installed. Copy the command from Settings > AI Assistants, which uses the path
of the copy that's running.

Settings shows an error for the server: it couldn't create the socket. Turn
the setting off and on again, or relaunch Memoir.
