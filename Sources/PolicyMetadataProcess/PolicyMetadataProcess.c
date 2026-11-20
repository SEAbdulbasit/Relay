#include "PolicyMetadataProcess.h"
#include <libproc.h>
#include <sys/resource.h>

// Actual system metadata only. No process enumeration, signaling or input API.
int relay_policy_process_identity(int pid, uint64_t *start, char *path, size_t capacity) {
    if (pid <= 0 || start == NULL || path == NULL || capacity < 2 || capacity > 4096) return -1;
    struct rusage_info_v0 info = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&info) != 0 || info.ri_proc_start_abstime == 0) return -1;
    if (proc_pidpath(pid, path, (uint32_t)capacity) <= 0) return -1;
    path[capacity - 1] = 0;
    *start = info.ri_proc_start_abstime;
    return 0;
}

// Direct owned-CLI parent metadata. No enumeration, signaling or input.
int relay_policy_process_parent(int pid, int *parent) {
    if (pid <= 0 || parent == NULL) return -1;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    if (info.pbi_pid != (uint32_t)pid || info.pbi_ppid == 0) return -1;
    *parent = (int)info.pbi_ppid;
    return 0;
}

#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

// KERN_PROCARGS2's kernel argc is authoritative for this already-proven owned
// CLI lifetime. Parse only those entries, never the following environment.
// This closed Process.run path has nonempty argv[0] equal to executable path;
// do not generalize this parser to arbitrary process/empty-argv0 inspection.
int relay_policy_parse_arguments(const unsigned char *buffer, size_t length, char *output, size_t capacity, size_t *used, int *argc) {
    if (!buffer || !output || !used || !argc || capacity == 0 || capacity > 65536 || length < sizeof(int)) return -1;
    *used = 0; *argc = 0; (void)memset_s(output, capacity, 0, capacity);
    int count = 0; memcpy(&count, buffer, sizeof(count));
    if (count < 1 || count > 256) return -1;
    size_t offset = sizeof(int), executable = offset;
    while (offset < length && buffer[offset] != 0 && offset - executable <= 4096) offset++;
    if (offset == length || offset == executable || offset - executable > 4096) return -1;
    size_t executable_length = offset - executable;
    while (offset < length && buffer[offset] == 0) offset++;
    if (offset >= length || executable_length >= length - offset ||
        memcmp(buffer + offset, buffer + executable, executable_length) != 0 || buffer[offset + executable_length] != 0) return -1;
    size_t total = 0;
    for (int index = 0; index < count; index++) {
        size_t start = offset;
        while (offset < length && buffer[offset] != 0 && offset - start <= 16384) offset++;
        if (offset == length || offset - start > 16384 || offset - start + 1 > capacity - total) {
            (void)memset_s(output, total, 0, total); return -1;
        }
        size_t amount = offset - start + 1;
        memcpy(output + total, buffer + start, amount);
        total += amount; offset++;
    }
    *used = total; *argc = count;
    return 0;
}
int relay_policy_process_arguments(int pid, char *output, size_t capacity, size_t *used, int *argc) {
    if (pid <= 0 || !output || !used || !argc || capacity == 0 || capacity > 65536) return -1;
    *used = 0; *argc = 0; (void)memset_s(output, capacity, 0, capacity);
    int max_args = 0; size_t max_size = sizeof(max_args);
    int limit_query[] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(limit_query, 2, &max_args, &max_size, NULL, 0) != 0 || max_args < 1 || max_args > 2 * 1024 * 1024) return -1;
    unsigned char *buffer = calloc(1, (size_t)max_args);
    if (!buffer) return -1;
    size_t length = (size_t)max_args;
    int query[] = { CTL_KERN, KERN_PROCARGS2, pid };
    int result = sysctl(query, 3, buffer, &length, NULL, 0);
    if (result == 0) result = relay_policy_parse_arguments(buffer, length, output, capacity, used, argc);
    (void)memset_s(buffer, (size_t)max_args, 0, (size_t)max_args); free(buffer);
    return result;
}

// Live kernel process lifetime only. No executable lookup, filesystem
// normalization, enumeration, arguments, signaling or input.
int relay_policy_process_start(int pid, uint64_t *start) {
    if (pid <= 0 || start == NULL) return -1;
    *start = 0;
    struct rusage_info_v0 info = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&info) != 0 || info.ri_proc_start_abstime == 0) return -1;
    *start = info.ri_proc_start_abstime;
    return 0;
}
