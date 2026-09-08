# Claude provider for rio

Adds **Anthropic's Claude** as an agent provider for rio's built-in agent. It talks to
the hosted Anthropic API; you supply your own API key.

- **Kind:** provider (`provider-api = 1`)
- **Needs:** an Anthropic API key (`sk-ant-…`).

## Install

1. In rio, open **Settings ▸ Extensions…**, click **Repositories…**, and add this
   repository's base URL (plain `http://`).
2. Back in the Extensions window, select **claude** and install it.
3. **Restart rio** — an installed provider becomes live on the next start.
4. Choose **Claude** as the agent provider and enter your API key when prompted.

`echo` (the built-in stub provider) stays available whether or not this is installed.
