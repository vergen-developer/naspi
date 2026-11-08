# Graph Report - naspi  (2026-09-10)

## Corpus Check
- 4 files · ~5,270 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 74 nodes · 166 edges · 10 communities (9 shown, 1 thin omitted)
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

## God Nodes (most connected - your core abstractions)
1. `main()` - 21 edges
2. `log()` - 14 edges
3. `install_tailscale()` - 13 edges
4. `skip()` - 11 edges
5. `main()` - 9 edges
6. `warn()` - 9 edges
7. `apt_ok()` - 8 edges
8. `die()` - 7 edges
9. `run_to()` - 7 edges
10. `pkg_first()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `ensure_swap()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 4_
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `install_tailscale()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 2 → community 3_
- `start_samba()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 2 → community 4_

## Import Cycles
- None detected.

## Communities (10 total, 1 thin omitted)

### Community 0 - "install.sh"
Cohesion: 0.18
Nodes (6): APT_LISTCHANGES_FRONTEND, DEBCONF_NONINTERACTIVE_SEEN, DEBIAN_FRONTEND, NEEDRESTART_MODE, NEEDRESTART_SUSPEND, UCF_FORCE_CONFFOLD

### Community 1 - "log"
Cohesion: 0.28
Nodes (13): apt_ok(), apt_prepare(), bring_up_tailscale(), install_fs_helper(), install_usb_automount(), log(), pkg_first(), pkg_installed() (+5 more)

### Community 2 - "main"
Cohesion: 0.22
Nodes (11): detect_user(), die(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds(), install.sh script (+3 more)

### Community 3 - "install_tailscale"
Cohesion: 0.40
Nodes (6): bin_runs(), http_get(), install_static_tailscale(), install_tailscale(), is_armv6(), set_ts_flags()

### Community 4 - "skip"
Cohesion: 0.36
Nodes (8): enable_boot(), ensure_swap(), run_to(), set_hostname(), skip(), start_samba(), start_tailscaled(), write_avahi()

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 7 - "format-usb.sh"
Cohesion: 0.24
Nodes (11): attach_nas(), die(), disk_readable(), format_disk(), is_usb_disk(), log(), main(), need_tools() (+3 more)

## Knowledge Gaps
- **6 isolated node(s):** `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE`, `NEEDRESTART_SUSPEND`, `UCF_FORCE_CONFFOLD` (+1 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`, `skip`?**
  _High betweenness centrality (0.029) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`, `skip`?**
  _High betweenness centrality (0.010) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`, `skip`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE` to the rest of the system?**
  _6 weakly-connected nodes found - possible documentation gaps or missing edges._