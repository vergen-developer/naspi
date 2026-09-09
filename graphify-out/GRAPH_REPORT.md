# Graph Report - naspi  (2026-09-09)

## Corpus Check
- 2 files · ~4,152 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 66 nodes · 147 edges · 5 communities
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ae4d23c2`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- log
- main
- install_tailscale
- format-usb.sh

## God Nodes (most connected - your core abstractions)
1. `main()` - 20 edges
2. `log()` - 14 edges
3. `install_tailscale()` - 12 edges
4. `warn()` - 9 edges
5. `main()` - 7 edges
6. `die()` - 7 edges
7. `run_to()` - 7 edges
8. `pkg_first()` - 7 edges
9. `apt_ok()` - 7 edges
10. `setup_share_dir()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `ensure_swap()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `install_tailscale()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 2 → community 3_

## Import Cycles
- None detected.

## Communities (5 total, 0 thin omitted)

### Community 0 - "install.sh"
Cohesion: 0.15
Nodes (11): APT_LISTCHANGES_FRONTEND, DEBCONF_NONINTERACTIVE_SEEN, DEBIAN_FRONTEND, http_pipe(), latest_static_ver(), NEEDRESTART_MODE, NEEDRESTART_SUSPEND, ts_authurl() (+3 more)

### Community 1 - "log"
Cohesion: 0.28
Nodes (13): apt_ok(), apt_prepare(), bring_up_tailscale(), install_fs_helper(), install_usb_automount(), log(), pkg_first(), pkg_installed() (+5 more)

### Community 2 - "main"
Cohesion: 0.19
Nodes (13): detect_user(), die(), enable_boot(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds() (+5 more)

### Community 3 - "install_tailscale"
Cohesion: 0.24
Nodes (10): bin_runs(), ensure_swap(), http_get(), install_static_tailscale(), install_tailscale(), is_armv6(), run_to(), set_hostname() (+2 more)

### Community 7 - "format-usb.sh"
Cohesion: 0.27
Nodes (9): attach_nas(), die(), format_disk(), is_usb_disk(), log(), main(), need_tools(), format-usb.sh script (+1 more)

## Knowledge Gaps
- **6 isolated node(s):** `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE`, `NEEDRESTART_SUSPEND`, `UCF_FORCE_CONFFOLD` (+1 more)
  These have ≤1 connection - possible missing edges or undocumented components.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`, `NEEDRESTART_MODE` to the rest of the system?**
  _6 weakly-connected nodes found - possible documentation gaps or missing edges._