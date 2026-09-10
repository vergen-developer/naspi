# Graph Report - naspi  (2026-09-10)

## Corpus Check
- 3 files · ~4,957 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 70 nodes · 160 edges · 9 communities (8 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `620fff3f`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- warn
- main
- install_tailscale
- log
- ts_field
- format-usb.sh
- http_pipe

## God Nodes (most connected - your core abstractions)
1. `main()` - 20 edges
2. `log()` - 14 edges
3. `install_tailscale()` - 13 edges
4. `skip()` - 11 edges
5. `warn()` - 9 edges
6. `apt_ok()` - 8 edges
7. `main()` - 7 edges
8. `die()` - 7 edges
9. `run_to()` - 7 edges
10. `pkg_first()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `apt_ok()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 4 → community 1_
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 4 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 4 → community 2_
- `install_tailscale()` --calls--> `warn()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `write_smb_conf()` --calls--> `warn()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_

## Import Cycles
- None detected.

## Communities (9 total, 1 thin omitted)

### Community 0 - "install.sh"
Cohesion: 0.18
Nodes (6): APT_LISTCHANGES_FRONTEND, DEBCONF_NONINTERACTIVE_SEEN, DEBIAN_FRONTEND, NEEDRESTART_MODE, NEEDRESTART_SUSPEND, UCF_FORCE_CONFFOLD

### Community 1 - "warn"
Cohesion: 0.29
Nodes (10): apt_ok(), apt_prepare(), install_fs_helper(), install_usb_automount(), pkg_first(), pkg_installed(), preseed_debconf(), setup_share_dir() (+2 more)

### Community 2 - "main"
Cohesion: 0.24
Nodes (11): detect_user(), die(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds(), install.sh script (+3 more)

### Community 3 - "install_tailscale"
Cohesion: 0.33
Nodes (7): bin_runs(), http_get(), install_static_tailscale(), install_tailscale(), is_armv6(), set_ts_flags(), start_tailscaled()

### Community 4 - "log"
Cohesion: 0.42
Nodes (9): bring_up_tailscale(), enable_boot(), ensure_swap(), log(), run_to(), set_hostname(), skip(), start_samba() (+1 more)

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 7 - "format-usb.sh"
Cohesion: 0.27
Nodes (9): attach_nas(), die(), format_disk(), is_usb_disk(), log(), main(), need_tools(), format-usb.sh script (+1 more)

## Knowledge Gaps
- **6 isolated node(s):** `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE`, `NEEDRESTART_SUSPEND`, `UCF_FORCE_CONFFOLD` (+1 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `warn`, `install_tailscale`, `log`?**
  _High betweenness centrality (0.029) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `warn`, `main`, `log`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `warn`, `main`, `install_tailscale`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE` to the rest of the system?**
  _6 weakly-connected nodes found - possible documentation gaps or missing edges._