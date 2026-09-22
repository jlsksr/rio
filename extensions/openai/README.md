# OpenAI provider for rio

Adds an **OpenAI-compatible** agent provider for rio's built-in agent. Point it at hosted
**ChatGPT** with an OpenAI API key, or at a server of your own that speaks the same
protocol — Ollama, llama.cpp / llama-server, llama-swap, vLLM, LM Studio — by its URL.
A server of your own usually needs no key at all.

- **Kind:** provider (`provider-api = 4`)
- **Needs:** an OpenAI API key (`sk-…`) for hosted ChatGPT, **or** just the URL of your
  own server.

## Install

1. In rio, open **Settings ▸ Extensions…**, click **Repositories…**, and add this
   repository's base URL.
2. Back in the Extensions window, select **openai** and install it.
3. **Restart rio** — an installed provider becomes live on the next start.
4. Choose **OpenAI-compatible** as the agent provider, then open
   **Preferences ▸ Agent ▸ OpenAI-compatible settings…**.

## Settings

Everything is set in that window, and saved on the machine the core runs on.

| | |
|---|---|
| **Model** | Which model answers. **⟳ Refresh from provider** lists what the server actually offers — do that after changing the URL. |
| **Effort** | Reasoning effort, for a model that takes one. The default sends nothing. |
| **Reasoning** | Whether a thinking model's reasoning is shown in the chat. It is never part of the answer and is never sent back to the model. |
| **Server URL** | The API base without a trailing path — `https://api.openai.com/v1`, or `http://your-box:11434/v1`. rio adds `/chat/completions` and `/models` itself. |
| **Max tokens** | The cap on one reply's length. |
| **Request timeout** | How long one whole turn may take. It bounds the whole exchange, so a long generation or a server that loads a model on demand needs a generous value. |
| **Token cap field** | `max_tokens` for most servers; newer hosted OpenAI models want `max_completion_tokens` and say so in a 400, which rio then remembers per model. |
| **Extra request JSON** | A JSON object merged into every request — `temperature`, `top_p`, or whatever this server understands (llama.cpp and vLLM take `chat_template_kwargs`). Fields rio sends itself are refused here. |

The two **Advanced** URLs are for a server whose paths are not under one base; blank means
they are derived from the Server URL.

`echo` (the built-in stub provider) stays available whether or not this is installed.

## License

MIT, like rio itself — see the `LICENSE` in the rio source tree or in the repository this
came from. Each of the three payload files repeats the notice in its own header, because
an installed extension lands in the provider store on its own, with no LICENSE beside it.

Whatever service you point it at — OpenAI's, or a local server — is governed by that
service's own terms; this extension is only the client.
