# Changing projects state (moving to incubation, graduating etc)

- Update status in `*/projects.yaml`.
- Add `graduated_date` or similar (`incubating_date`, `archived_date`).
- Follow instructions from `cncf/devstats`:`GRADUATING.md`.

Update helm:
- Recreate grafana pods (new dashboards links on home dashboard).
- Recreate static pages (by killing static pages pods).
- Rerun vars on all projects (should also handle projects health(s) dashboards).
