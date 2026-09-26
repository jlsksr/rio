# Working remotely

Keep the window local and edit files on a server. Install rio on your workstation
first; use the same version on both machines. See [installation](../INSTALL.md).

## Start the server

In the rio checkout on the server:

```sh
./install-server.sh
tclsh rio-core/server.tcl 7711
```

Leave it running. Keep the default `127.0.0.1` binding: the core has no
authentication or encryption; the SSH tunnel supplies both.

## Connect from your workstation

Open a tunnel, replacing `you@server` with your SSH login:

```sh
ssh -N -L 127.0.0.1:7711:127.0.0.1:7711 you@server
```

Leave that terminal open. In another terminal, from your local rio checkout:

```sh
wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server
```

Replace `/path/on/server` with your remote project directory. Alternatively, use
***File ▸ Connect to Remote Core…***, enter `127.0.0.1:7711`, then open the folder.

## While connected

- File dialogs, saves, search, git, and the agent use the server. API keys are
  stored there too; `localhost` in a model URL means the server.
- Window preferences stay local. Desktop file drops do not upload files.
- Recovery copies of your unsaved changes are kept by the core, so they land on
  the server beside the files themselves — see
  [keeping your unsaved changes](editor.md#keeping-your-unsaved-changes).
- If the connection drops, check the core and tunnel, restore them, then reconnect
  through ***File ▸ Connect to Remote Core…***. Reconnection is not automatic.
- When finished, save and close rio, then stop the tunnel and server with
  **Ctrl+C** in their terminals.

[Deployment options](../INSTALL.md#4-deployment-modes) · [Agent setup](agent.md)
