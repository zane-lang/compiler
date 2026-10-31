typedef struct io_t io_t;
typedef struct other_t other_t;
extern io_t io_global;
extern io_t io_declared;
extern _Thread_local io_t io_thread;
extern other_t io_other;
extern const io_t io_constant;
