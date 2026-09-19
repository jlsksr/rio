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

## License

MIT, like rio itself — see the `LICENSE` in the rio source tree or in the repository this
came from. Each of the three payload files repeats the notice in its own header, because
an installed extension lands in the provider store on its own, with no LICENSE beside it.

The Anthropic API this talks to is Anthropic's, and your use of it is between you and
them; this extension is only the client.
