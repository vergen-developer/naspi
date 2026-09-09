# Graph Report - naspi  (2026-09-09)

## Corpus Check
- 1 files · ~2,792 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 41 nodes · 86 edges · 9 communities (6 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `82586956`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- install.sh
- log
- main
- install_tailscale
- die
- ts_field
- setup_share_dir
- start_samba
- save_creds

## God Nodes (most connected - your core abstractions)
1. `main()` - 20 edges
2. `log()` - 11 edges
3. `install_tailscale()` - 10 edges
4. `setup_share_dir()` - 6 edges
5. `warn()` - 5 edges
6. `die()` - 4 edges
7. `bring_up_tailscale()` - 4 edges
8. `wait_tailscale_login()` - 4 edges
9. `need_root()` - 3 edges
10. `detect_user()` - 3 edges

## Surprising Connections (you probably didn't know these)
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `setup_share_dir()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 6_
- `install_tailscale()` --calls--> `die()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 4 → community 3_
- `main()` --calls--> `need_root()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 4 → community 2_

## Import Cycles
- None detected.

## Communities (9 total, 3 thin omitted)

### Community 1 - "log"
Cohesion: 0.29
Nodes (8): apt_ok(), bring_up_tailscale(), ensure_swap(), log(), set_hostname(), wait_tailscale_login(), warn(), write_smb_conf()

### Community 2 - "main"
Cohesion: 0.33
Nodes (6): lower_gpu_mem(), main(), print_report(), install.sh script, write_avahi(), write_cli()

### Community 3 - "install_tailscale"
Cohesion: 0.33
Nodes (6): bin_runs(), install_static_tailscale(), install_tailscale(), is_armv6(), set_ts_flags(), start_tailscaled()

### Community 4 - "die"
Cohesion: 0.67
Nodes (3): detect_user(), die(), need_root()

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 6 - "setup_share_dir"
Cohesion: 0.67
Nodes (3): install_fs_helper(), install_usb_automount(), setup_share_dir()

## Knowledge Gaps
- **2 isolated node(s):** `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND`
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`, `die`, `setup_share_dir`, `start_samba`, `save_creds`?**
  _High betweenness centrality (0.097) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`, `die`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`, `setup_share_dir`?**
  _High betweenness centrality (0.016) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND` to the rest of the system?**
  _2 weakly-connected nodes found - possible documentation gaps or missing edges._