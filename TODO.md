# Ubuntu ZFS Installer - TODO

## 🚨 Critical Issues
- [ ] **CRITICAL**: Fix Ansible secrets loading for system users creation
  - [ ] Focus on henry user only for now (timemachine/paperless users temporarily disabled)
  - [ ] system_users task may still skip due to missing secrets.users variables  
  - [ ] Need to load secrets.sops.yaml or provide mechanism for password-less user creation in build environment
- [ ] **CRITICAL**: Add tests for get-ubuntu-version.sh script to prevent regression
- [ ] **CRITICAL**: Add tests for ubuntu-api.sh _get_latest_ubuntu_version function  
- [ ] **CRITICAL**: Add tests for run_cmd_read with complex piped commands
- [ ] **CRITICAL**: Separate container creation from package installation in Stage 5
  - [ ] Split Stage 5 into: 5a) Create container, 5b) Install packages  
  - [ ] Ensures package installation failures are properly detected and handled
  - [ ] Allows for better error recovery and debugging of package installation issues
- [ ] Fix truncated help message from manage-build-status.sh

## 🔥 Next Phase Priorities

### Code Quality Improvements
- [ ] **Improve error handling consistency**
  - [ ] Standardize error messages across scripts
  - [ ] Ensure all scripts use proper exit codes consistently
  - [ ] Add more defensive programming patterns where beneficial
- [ ] **Optimize verbose flag usage**
  - [ ] Review mmdebstrap progress messages in install-root-os.sh
  - [ ] Review Ansible configuration feedback in configure-root-os.sh
  - [ ] Review orchestration status messages in build-new-root.sh
  - [ ] Control cleanup/debug output verbosity consistently

### Function Isolation Improvements  
- [ ] **Reduce global variable dependencies**
  - [ ] Refactor validation functions to accept parameters instead of globals
  - [ ] Refactor ZFS functions to accept parameters instead of globals
  - [ ] Update function calls throughout codebase to use parameters
- [ ] **Improve function composability**
  - [ ] Ensure functions have single responsibilities
  - [ ] Add proper return codes for all functions
  - [ ] Document function contracts and interfaces

## 🚀 Future Enhancements

### ZFSBootMenu Integration & Version Management
- [x] **Phase 1: Core ZFSBootMenu Management** (HIGH PRIORITY) - **COMPLETED**
  - [x] Create `scripts/manage-zfsbootmenu.sh` following established script patterns
    - [x] Use shflags for standardized argument parsing
    - [x] Implement common flag definitions (--dry-run, --debug, --help)
    - [x] Follow logging patterns from existing scripts
    - [x] Support operations: ~~version, check,~~ status (consolidated into single command)
  - [x] Create `lib/zfsbootmenu.sh` library following modular architecture
    - [x] Functions: `zfsbootmenu_get_installed_version()`, `zfsbootmenu_get_latest_version()`, `zfsbootmenu_check_installation()`
    - [x] Use existing patterns: prevent multiple sourcing guards, proper error handling
    - [x] Integration with `run_cmd()` and `run_cmd_read()` from execution.sh
    - [x] Support for dry-run mode simulation
    - [x] Correct ZFSBootMenu detection (EFI images, generate-zbm script, config directory)
    - [x] **Enhanced EFI Discovery**: Multi-partition support, professional tabular output
    - [x] **Boot Detection**: GPT UUID-based detection of last booted EFI file
    - [x] **Version Detection**: SHA256 checksum matching against 65-entry database
    - [x] **DRY Refactoring**: Consolidated search directory logic with helper functions
  - [x] Add ZFSBootMenu constants to `lib/constants.sh`
    - [x] Updated paths to match actual ZFSBootMenu installation patterns
    - [x] EFI mount points, configuration paths, GitHub URLs
    - [x] **Configurable Search Directories**: Support for multiple EFI partitions
  - [x] **Checksum Database**: Automated via `tools/update-vendor-deps.sh`
    - [x] 65 checksums from 13 ZFSBootMenu releases (v1.9.0 to v3.0.1)
    - [x] GitHub API integration for automatic updates
  - [ ] Add comprehensive test coverage following existing patterns
    - [ ] Unit tests for all library functions in `test/unit/zfsbootmenu.bats`
    - [ ] Mock external dependencies (GitHub API, file operations)
    - [ ] Test dry-run behavior and error conditions

- [ ] **Phase 2: EFI Integration & Image Management** (MEDIUM PRIORITY)
  - [ ] Extend `lib/zfsbootmenu.sh` with EFI management functions
    - [ ] `zfsbootmenu_update_efi()`, `zfsbootmenu_generate_images()`
    - [ ] Support multiple EFI partitions (like existing `/boot/efi`, `/boot/efi2`)
    - [ ] Proper mount point validation using existing patterns
  - [ ] Add Ansible role: `ansible/roles/zfsbootmenu/`
    - [ ] Templates for ZBM configuration following existing role patterns
    - [ ] Handlers for image regeneration
    - [ ] Integration with existing host_vars structure
  - [ ] Configuration management in `config/` directory
    - [ ] Add ZBM settings to `global.conf` or separate config file
    - [ ] Host-specific ZBM configuration in host_vars
  - [ ] Enhanced testing for EFI operations
    - [ ] Mock EFI mount points and file operations
    - [ ] Test configuration template generation

- [ ] **Phase 3: Boot Environment Integration** (MEDIUM PRIORITY)  
  - [ ] Enhance existing `lib/zfs.sh` with ZBM-specific properties
    - [ ] Functions to set/get `org.zfsbootmenu:*` properties
    - [ ] Integration with existing `zfs_promote_to_bootfs()` function
    - [ ] Follow existing ZFS operation patterns
  - [ ] Extend `scripts/build-new-root.sh` with optional ZBM stage
    - [ ] New stage: `stage_8_update_zfsbootmenu` following existing stage patterns
    - [ ] Status tracking integration using existing build-status system
    - [ ] Proper flag propagation and dry-run support
  - [ ] Kernel management integration
    - [ ] Functions to extract kernels from boot environments
    - [ ] Update ZBM kernel cache following existing file operation patterns
  - [ ] Comprehensive integration testing
    - [ ] Test ZBM property management
    - [ ] Test integration with existing build process

- [ ] **Phase 4: Advanced Version Management** (LOW PRIORITY)
  - [ ] Version history and rollback capabilities
    - [ ] `zfsbootmenu_backup_version()`, `zfsbootmenu_rollback_version()`
    - [ ] Follow existing snapshot naming conventions and cleanup patterns
  - [ ] Automated update checking and notifications
    - [ ] Integration with existing logging system
    - [ ] Respect dry-run and debug modes
  - [ ] Enhanced monitoring and validation
    - [ ] Health checks for ZBM installation
    - [ ] Integration with existing validation patterns

### Code Design Patterns & Standards
- [ ] **ZFSBootMenu Implementation Requirements**
  - [ ] **Testing**: Achieve 100% test coverage following existing bats patterns
    - [ ] Mock all external dependencies (GitHub API, file operations, EFI mounts)
    - [ ] Test all error conditions and edge cases
    - [ ] Validate dry-run mode behavior for all operations
  - [ ] **DRY Principles**: Reuse existing library functions where possible
    - [ ] Use `run_cmd()` and `run_cmd_read()` for all command execution
    - [ ] Leverage existing logging, validation, and error handling patterns
    - [ ] Avoid duplicating functionality from existing libraries
  - [ ] **Decomposition**: Follow established modular architecture
    - [ ] Library functions in `lib/zfsbootmenu.sh` with single responsibilities
    - [ ] Script orchestration in `scripts/manage-zfsbootmenu.sh`
    - [ ] Configuration management separate from operational logic
  - [ ] **Logging Integration**: Use existing logging framework
    - [ ] Support DEBUG, INFO, WARN, ERROR levels consistently
    - [ ] Integration with build-specific logging context
    - [ ] Proper timestamp and formatting following existing patterns
  - [ ] **Flag Standardization**: Use established flag patterns
    - [ ] Common flags: `--dry-run`, `--debug`, `--help`, `--pool`
    - [ ] Use `define_common_flags()` and `process_common_flags()`
    - [ ] Consistent help message formatting following existing scripts
  - [ ] **Dry-Run Support**: Full simulation capability
    - [ ] All operations must support `--dry-run` mode
    - [ ] Show exact commands that would be executed
    - [ ] Validate inputs without making changes
  - [ ] **Error Handling**: Follow existing error patterns
    - [ ] Use `die()` function for fatal errors with proper context
    - [ ] Consistent exit codes following `lib/constants.sh`
    - [ ] Proper cleanup on failure following existing patterns

### Advanced Tooling Integration
- [ ] **Consider bash-commons integration**
  - [ ] Evaluate bash-commons vs current implementations
  - [ ] Plan migration strategy if beneficial over current libraries
- [ ] **Enhanced debugging capabilities**  
  - [ ] Performance profiling capabilities
  - [ ] Add tracing support for complex operations

### Maintenance Automation
- [ ] **Additional automation**
  - [ ] Add automated dependency updates
  - [ ] Add automated code formatting with shfmt
  - [ ] Add release automation

## � Current Status

### ✅ Major Achievements (2025)
- **Testing**: 227 tests, 100% coverage across 11 libraries
- **Quality**: Zero shellcheck warnings, zero static analysis errors  
- **CI/CD**: Comprehensive GitHub Actions pipeline with quality gates
- **Architecture**: Modular library system with centralized execution
- **Documentation**: Professional README with status badges and metrics

### 🛠️ Tool Status
- ✅ **shellcheck, checkbashisms, yaml-check** - Complete with zero issues
- ✅ **bats-core testing** - 227 tests, 100% coverage, Docker integration
- ✅ **shflags** - Integrated across all 9 scripts
- ✅ **Centralized execution system** - Unified debug/verbose/dry-run logic
- [ ] **shfmt** - Not integrated (code formatting - low priority)
- [ ] **bash-commons** - Not evaluated (low priority)

---

*This document tracks remaining work items. See README.md for current capabilities and achievements.*
