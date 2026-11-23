#define FFI_SCOPE "example"
#define FFI_LIB "libexample.so"
typedef struct Point { int32_t x; double y; } Point;
enum Color { RED, GREEN = 5, BLUE };
void draw(Point *p, enum Color c, void (*cb)(int32_t x), ...);
const char *name(uint8_t buf[16]);
union U { float f; int64_t i; };
