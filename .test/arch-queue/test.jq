include "jenkins";

# force every build to look like it still needs to happen, so we exercise the full "get_arch_queue" annotation logic (cross, windowsVersion) against real data instead of synthetic fixtures
.[].build.resolved = null
| get_arch_queue("amd64", "windows-amd64")
