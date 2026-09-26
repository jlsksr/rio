# Working remotely

Keep the window on your own machine and edit files on a server.

Install rio on both machines, at the same version. See
[installation](../INSTALL.md).

## 1. Start the core on the server

In the rio checkout on the server:

```sh
./install-server.sh
tclsh rio-core/server.tcl 7711
```

Leave it running. Keep the default `127.0.0.1` binding: the core has no
authentication and no encryption, and the SSH tunnel supplies both.

## 2. Open a tunnel

On your own machine, replacing `you@server` with your SSH login:

```sh
ssh -N -L 127.0.0.1:7711:127.0.0.1:7711 you@server
```

Leave that terminal open.

## 3. Connect

In another terminal, from your local rio checkout:

```sh
wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server
```

Replace `/path/on/server` with your project directory on the server. Or start
rio normally, choose ***File ▸ Connect to Remote Core…***, enter
`127.0.0.1:7711`, and open the folder from there.

## While connected

- File dialogs, saves, search, git and the agent all use the **server**. API
  keys are stored there too, and `localhost` in a model URL means the server.
- Window preferences stay local. Files dropped from your desktop are not
  uploaded.
- Recovery copies of your unsaved changes are kept by the core, so they land on
  the server beside the files themselves. See [keeping your unsaved
  changes](editor.md#keeping-your-unsaved-changes).
- **If the connection drops**, check the core and the tunnel, restore them, then
  reconnect with ***File ▸ Connect to Remote Core…***. Reconnection is not
  automatic.
- **When you finish**, save and close rio, then stop the tunnel and the core
  with `Ctrl+C` in their terminals.

[Deployment options](../INSTALL.md#4-deployment-modes) · [Agent setup](agent.md)
