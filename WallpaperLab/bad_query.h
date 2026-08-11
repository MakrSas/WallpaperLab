#ifndef BAD_QUERY_H
#define BAD_QUERY_H

#include <stdbool.h>
#include <stdint.h>

int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group);
void bad_query_release(int64_t handle);
char *bad_query_list(char *path, int max);

#endif

