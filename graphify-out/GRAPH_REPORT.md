# Graph Report - naspi  (2026-11-08)

## Corpus Check
- 5 files · ~7,025 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 79 nodes · 171 edges · 12 communities (11 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a992122e`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- log
- main
- install_tailscale
- skip
- ts_field
- format-usb.sh
- http_pipe
- NASPI
- usb_ssd_stable

## God Nodes (most connected - your core abstractions)
1. `main()` - 23 edges
2. `log()` - 15 edges
3. `install_tailscale()` - 13 edges
4. `warn()` - 11 edges
5. `skip()` - 10 edges
6. `die()` - 8 edges
7. `apt_ok()` - 8 edges
8. `run_to()` - 7 edges
9. `start_samba()` - 7 edges
10. `pkg_first()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `ensure_swap()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 4_
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `usb_ssd_stable()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 11_
- `install_tailscale()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 2 → community 3_

## Import Cycles
- None detected.

## Communities (12 total, 1 thin omitted)

### Community 0 - "install.sh"
Cohesion: 0.17
Nodes (8): APT_LISTCHANGES_FRONTEND, DEBCONF_NONINTERACTIVE_SEEN, DEBIAN_FRONTEND, install_usb_automount(), NEEDRESTART_MODE, NEEDRESTART_SUSPEND, pkg_installed(), UCF_FORCE_CONFFOLD

### Community 1 - "log"
Cohesion: 0.40
Nodes (10): apt_ok(), apt_prepare(), bring_up_tailscale(), log(), pkg_first(), preseed_debconf(), setup_share_dir(), wait_tailscale_login() (+2 more)

### Community 2 - "main"
Cohesion: 0.24
Nodes (11): detect_user(), die(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds(), install.sh script (+3 more)

### Community 3 - "install_tailscale"
Cohesion: 0.33
Nodes (7): bin_runs(), http_get(), install_format_tool(), install_static_tailscale(), install_tailscale(), is_armv6(), set_ts_flags()

### Community 4 - "skip"
Cohesion: 0.36
Nodes (8): enable_boot(), ensure_swap(), run_to(), set_hostname(), skip(), start_samba(), start_tailscaled(), write_avahi()

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 7 - "format-usb.sh"
Cohesion: 0.30
Nodes (7): attach_nas(), die(), format_disk(), log(), main(), format-usb.sh script, unmount_disk()

### Community 10 - "NASPI"
Cohesion: 0.29
Nodes (6): Comandi, Installazione (un comando), NASPI, Pi 1: alimentazione (obbligatorio), SSD USB, Windows

### Community 11 - "usb_ssd_stable"
Cohesion: 0.67
Nodes (3): cmdline_set(), config_set(), usb_ssd_stable()

## Knowledge Gaps
- **10 isolated node(s):** `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE`, `NEEDRESTART_SUSPEND`, `UCF_FORCE_CONFFOLD` (+5 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`, `skip`, `usb_ssd_stable`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`, `skip`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`, `skip`, `usb_ssd_stable`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE` to the rest of the system?**
  _10 weakly-connected nodes found - possible documentation gaps or missing edges._