# Graph Report - naspi  (2026-09-09)

## Corpus Check
- 2 files · ~4,062 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 60 nodes · 132 edges · 8 communities (5 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ec69f004`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- log
- main
- install_tailscale
- install_static_tailscale
- ts_field
- http_pipe
- format-usb.sh

## God Nodes (most connected - your core abstractions)
1. `main()` - 20 edges
2. `log()` - 13 edges
3. `install_tailscale()` - 11 edges
4. `warn()` - 9 edges
5. `main()` - 7 edges
6. `die()` - 7 edges
7. `apt_ok()` - 7 edges
8. `pkg_first()` - 6 edges
9. `setup_share_dir()` - 6 edges
10. `die()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 4_
- `install_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `install_tailscale()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 2 → community 3_
- `install_tailscale()` --calls--> `http_pipe()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 6 → community 3_

## Import Cycles
- None detected.

## Communities (8 total, 3 thin omitted)

### Community 1 - "log"
Cohesion: 0.26
Nodes (13): apt_ok(), apt_prepare(), bring_up_tailscale(), ensure_swap(), install_fs_helper(), install_usb_automount(), log(), pkg_first() (+5 more)

### Community 2 - "main"
Cohesion: 0.19
Nodes (14): detect_user(), die(), enable_boot(), lower_gpu_mem(), main(), need_root(), print_report(), save_creds() (+6 more)

### Community 3 - "install_tailscale"
Cohesion: 0.40
Nodes (5): bin_runs(), install_tailscale(), is_armv6(), set_ts_flags(), start_tailscaled()

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 7 - "format-usb.sh"
Cohesion: 0.27
Nodes (9): attach_nas(), die(), format_disk(), is_usb_disk(), log(), main(), need_tools(), format-usb.sh script (+1 more)

## Knowledge Gaps
- **2 isolated node(s):** `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND`
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`, `install_static_tailscale`, `http_pipe`?**
  _High betweenness centrality (0.012) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`, `install_static_tailscale`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND` to the rest of the system?**
  _2 weakly-connected nodes found - possible documentation gaps or missing edges._