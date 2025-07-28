# Ubuntu ZFS Installer - TODO

## 🚨 Critical Issues
- [ ] **CRITICAL**: Add tests for get-ubuntu-version.sh script to prevent regression
- [ ] **CRITICAL**: Add tests for ubuntu-api.sh _get_latest_ubuntu_version function  
- [ ] **CRITICAL**: Add tests for run_cmd_read with complex piped commands

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
