# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


### Added

- **Export operation** now supported for all resources:
  - `ActiveDirectory.GroupPolicy/GPO`
  - `ActiveDirectory.GroupPolicy/GPLink`
  - `ActiveDirectory.GroupPolicy/GPRegistryValue`
  - `ActiveDirectory.GroupPolicy/GPPrefRegistryValue`
- **Export scoping**: Declare the identifying property (`name` for GPO, `gpoName`/`target` for GPLink, etc.) to scope export to a single GPO or container; omit properties to export everything
- **Export example files** in `examples/` folder:
  - `export-all-resources.dsc.yaml` — exports every GPO, link, and registry value
  - `export-inventory.dsc.yaml` — exports a single GPO's metadata
  - `export-gpo-registry-values.dsc.yaml` — exports registry policy values for a single GPO
  - `export-gpo-pref-registry-values.dsc.yaml` — exports preference registry items for a single GPO
  - `export-linked-to-ou-.dsc.yaml` — exports GPO links (scoped by GPO name or target container)
- **Wiki documentation** for export functionality on each resource page

### Fixed

- **Registry export now discovers values correctly**: Fixed issue where `Get-GPRegistryValue` and `Get-GPPrefRegistryValue` were called with bare hive names (e.g., `HKEY_LOCAL_MACHINE`), which always yielded zero results. Added `Get-RegistryHiveRootKeys` helper to seed the export breadth-first search with valid first-level subkey paths.
- **Binary registry values now export compactly**: Registry values of type `Binary` are now serialized as Base64 strings (instead of huge per-byte JSON arrays), dramatically reducing export document size. The `ConvertTo-ByteArray` helper accepts either Base64 strings (from export/input) or legacy byte arrays (for backward compatibility).
- **Export no longer requires declared properties**: Removed schema-level `"required"` constraints from all resource `.dsc.resource.json` manifests, allowing bare resource declarations (no `properties` block) for full, unscoped export. Per-operation validation in `.ps1` scripts ensures that `Get`/`Test`/`Set` still enforce required properties.

### Changed

- **Binary value serialization format**: Updated `GPRegistryValue` and `GPPrefRegistryValue` resource schemas to document that `Binary` values are now represented as Base64-encoded strings (legacy byte-array input still accepted).
- **Export example comments**: Updated export YAML files to accurately reflect that declared properties now scope the export instead of being ignored.

### Documentation

- Added `export` operation documentation to each resource wiki page with scoping guidance
- Added export section to [Examples: All Resources](https://github.com/mimachniak/ADSGroupPolicyDSCv3/wiki/Examples-All-Resources#examples-all-resources)
- Updated [Home.md](https://github.com/mimachniak/ADSGroupPolicyDSCv3/wiki) with export CLI usage example
