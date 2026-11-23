typedef int (*handler_t)(void *ctx, const char *msg);
struct Node { struct Node *next; handler_t h; unsigned long long id : 8; };
extern struct Node *head;
