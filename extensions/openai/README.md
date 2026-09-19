# OpenAI provider for rio

Adds an **OpenAI-compatible** agent provider for rio's built-in agent. Point it at hosted
**ChatGPT** with an OpenAI API key, or at a **local OpenAI-compatible server** (Ollama,
llama-server, …) by its base URL — no key needed for a local server.

- **Kind:** provider (`provider-api = 1`)
- **Needs:** an OpenAI API key (`sk-…`) for hosted ChatGPT, **or** a base URL for a local
  OpenAI-compatible server.

## Install

1. In rio, open **Settings ▸ Extensions…**, click **Repositories…**, and add this
   repository's base URL (plain `http://`).
2. Back in the Extensions window, select **openai** and install it.
3. **Restart rio** — an installed provider becomes live on the next start.
4. Choose **OpenAI** as the agent provider, then enter your API key (hosted) or the base
   URL of your local server.

`echo` (the built-in stub provider) stays available whether or not this is installed.

## License

MIT, like rio itself — see the `LICENSE` in the rio source tree or in the repository this
came from. Each of the three payload files repeats the notice in its own header, because
an installed extension lands in the provider store on its own, with no LICENSE beside it.

Whatever service you point it at — OpenAI's, or a local server — is governed by that
service's own terms; this extension is only the client.
