# Graph Report - naspi  (2026-11-08)

## Corpus Check
- 5 files · ~8,898 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 82 nodes · 139 edges · 13 communities (10 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `73388be3`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- pkg_first
- main
- install_tailscale
- start_samba
- ts_field
- format-usb.sh
- http_pipe
- NASPI · VERGEN TECHNOLOGY
- usb_ssd_stable
- setup_share_dir

## God Nodes (most connected - your core abstractions)
1. `main()` - 25 edges
2. `install_tailscale()` - 9 edges
3. `run_to()` - 7 edges
4. `NASPI · VERGEN TECHNOLOGY` - 6 edges
5. `die()` - 5 edges
6. `main()` - 5 edges
7. `pkg_first()` - 5 edges
8. `format_disk()` - 4 edges
9. `usb_ssd_stable()` - 4 edges
10. `http_get()` - 4 edges

## Surprising Connections (you probably didn't know these)
- `start_samba()` --calls--> `run_to()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 3 → community 4_
- `main()` --calls--> `set_hostname()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 3 → community 2_
- `main()` --calls--> `usb_ssd_stable()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 11 → community 2_
- `main()` --calls--> `apt_ok()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `main()` --calls--> `setup_share_dir()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 12 → community 2_

## Import Cycles
- None detected.

## Communities (13 total, 3 thin omitted)

### Community 0 - "install.sh"
Cohesion: 0.20
Nodes (6): APT_LISTCHANGES_FRONTEND, DEBCONF_NONINTERACTIVE_SEEN, DEBIAN_FRONTEND, NEEDRESTART_MODE, NEEDRESTART_SUSPEND, UCF_FORCE_CONFFOLD

### Community 1 - "pkg_first"
Cohesion: 0.47
Nodes (6): apt_ok(), apt_prepare(), install_web(), pkg_first(), pkg_installed(), preseed_debconf()

### Community 2 - "main"
Cohesion: 0.14
Nodes (15): detect_user(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds(), install.sh script, smb_password() (+7 more)

### Community 3 - "install_tailscale"
Cohesion: 0.20
Nodes (12): bin_runs(), bring_up_tailscale(), ensure_swap(), http_get(), install_format_tool(), install_static_tailscale(), install_tailscale(), is_armv6() (+4 more)

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 7 - "format-usb.sh"
Cohesion: 0.30
Nodes (7): attach_nas(), die(), format_disk(), log(), main(), format-usb.sh script, unmount_disk()

### Community 10 - "NASPI · VERGEN TECHNOLOGY"
Cohesion: 0.25
Nodes (7): Comandi, Installazione (un comando), NASPI · VERGEN TECHNOLOGY, Pannello web, Pi 1: alimentazione (obbligatorio), SSD USB, Windows

### Community 11 - "usb_ssd_stable"
Cohesion: 0.67
Nodes (3): cmdline_set(), config_set(), usb_ssd_stable()

## Knowledge Gaps
- **11 isolated node(s):** `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE`, `NEEDRESTART_SUSPEND`, `UCF_FORCE_CONFFOLD` (+6 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `pkg_first`, `install_tailscale`, `start_samba`, `usb_ssd_stable`, `setup_share_dir`?**
  _High betweenness centrality (0.042) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `main`?**
  _High betweenness centrality (0.004) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE` to the rest of the system?**
  _11 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `main` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._