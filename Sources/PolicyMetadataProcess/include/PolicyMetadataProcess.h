#include <stddef.h>
#include <stdint.h>
int relay_policy_process_identity(int pid, uint64_t *start, char *path, size_t capacity);

int relay_policy_process_parent(int pid, int *parent);
// Test-only owned CLI argv: returns exact NUL-delimited argc entries only.
int relay_policy_parse_arguments(const unsigned char *buffer, size_t length, char *output, size_t capacity, size_t *used, int *argc);
int relay_policy_process_arguments(int pid, char *output, size_t capacity, size_t *used, int *argc);

// Fresh exact-PID kernel lifetime for lexical metadata identity checks.
int relay_policy_process_start(int pid, uint64_t *start);
