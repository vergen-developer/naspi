# Graph Report - naspi  (2026-09-09)

## Corpus Check
- 2 files · ~3,750 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 55 nodes · 116 edges · 10 communities (7 shown, 3 thin omitted)
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
- die
- ts_field
- setup_share_dir
- format-usb.sh
- main
- format_disk

## God Nodes (most connected - your core abstractions)
1. `main()` - 20 edges
2. `log()` - 11 edges
3. `install_tailscale()` - 10 edges
4. `main()` - 7 edges
5. `warn()` - 7 edges
6. `die()` - 7 edges
7. `setup_share_dir()` - 6 edges
8. `die()` - 5 edges
9. `apt_ok()` - 5 edges
10. `write_smb_conf()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `format_disk()` --calls--> `log()`  [EXTRACTED]
  format-usb.sh → format-usb.sh  _Bridges community 8 → community 9_
- `main()` --calls--> `attach_nas()`  [EXTRACTED]
  format-usb.sh → format-usb.sh  _Bridges community 7 → community 8_
- `install_static_tailscale()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 3_
- `main()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 2_
- `setup_share_dir()` --calls--> `log()`  [EXTRACTED]
  install.sh → install.sh  _Bridges community 1 → community 6_

## Import Cycles
- None detected.

## Communities (10 total, 3 thin omitted)

### Community 1 - "log"
Cohesion: 0.36
Nodes (8): apt_ok(), bring_up_tailscale(), ensure_swap(), log(), set_hostname(), wait_tailscale_login(), warn(), write_smb_conf()

### Community 2 - "main"
Cohesion: 0.29
Nodes (8): lower_gpu_mem(), main(), print_report(), save_creds(), install.sh script, smb_password(), write_avahi(), write_cli()

### Community 3 - "install_tailscale"
Cohesion: 0.33
Nodes (6): bin_runs(), install_static_tailscale(), install_tailscale(), is_armv6(), set_ts_flags(), start_tailscaled()

### Community 4 - "die"
Cohesion: 0.40
Nodes (5): detect_user(), die(), enable_boot(), need_root(), start_samba()

### Community 5 - "ts_field"
Cohesion: 0.67
Nodes (3): ts_authurl(), ts_field(), ts_state()

### Community 6 - "setup_share_dir"
Cohesion: 0.67
Nodes (3): install_fs_helper(), install_usb_automount(), setup_share_dir()

### Community 8 - "main"
Cohesion: 0.53
Nodes (6): die(), is_usb_disk(), log(), main(), need_tools(), format-usb.sh script

## Knowledge Gaps
- **2 isolated node(s):** `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND`
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `install.sh`, `log`, `install_tailscale`, `die`, `setup_share_dir`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **Why does `install_tailscale()` connect `install_tailscale` to `install.sh`, `log`, `main`, `die`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `log()` connect `log` to `install.sh`, `main`, `install_tailscale`, `setup_share_dir`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **What connects `DEBIAN_FRONTEND`, `APT_LISTCHANGES_FRONTEND` to the rest of the system?**
  _2 weakly-connected nodes found - possible documentation gaps or missing edges._