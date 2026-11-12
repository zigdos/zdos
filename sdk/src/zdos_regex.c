/* POSIX regular expressions (regex.h): pattern -> tree -> small program
 * (SPLIT, SAVE ...) run by a backtracking matcher. Its stack is on the heap
 * (threads have 64 KB of stack). For the longest match it keeps searching
 * after the first one, up to a step limit. */
#include <ctype.h>
#include <errno.h>
#include <regex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_GROUPS 32
#define MAX_PROG 32768
#define MAX_STEPS 10000000L

/* THE TREE */

enum {
    N_CHAR, N_ANY, N_SET, N_BOL, N_EOL, N_WORDB, N_NWORDB, N_WBEG, N_WEND,
    N_GROUP, N_CAT, N_ALT, N_REPEAT, N_BACKREF, N_EMPTY
};

typedef struct node {
    int type;
    int value;  /* N_CHAR: the byte; N_SET: the set; N_GROUP, N_BACKREF: the group */
    int min, max; /* N_REPEAT; max -1: no limit */
    struct node *a, *b; /* N_CAT, N_ALT: both; N_GROUP, N_REPEAT: a */
} node;

typedef struct {
    uint8_t bits[32];
} byteset;

typedef struct {
    const char *p;
    int flags;
    int error;
    int groups;
    node *nodes;
    int node_count, node_cap;
    byteset *sets;
    int set_count, set_cap;
} parser;

static node *new_node(parser *ps, int type) {
    if (ps->node_count == ps->node_cap) {
        /* Nodes stay in one array, linked by index-stable pointers: grow by
           chunks that never move (a list of blocks) */
        ps->error = REG_ESPACE;
        return NULL;
    }
    node *n = &ps->nodes[ps->node_count++];
    memset(n, 0, sizeof(*n));
    n->type = type;
    return n;
}

static int new_set(parser *ps) {
    if (ps->set_count == ps->set_cap) {
        int cap = ps->set_cap * 2 + 8;
        byteset *s = realloc(ps->sets, (size_t)cap * sizeof(byteset));
        if (s == NULL) {
            ps->error = REG_ESPACE;
            return -1;
        }
        ps->sets = s;
        ps->set_cap = cap;
    }
    memset(&ps->sets[ps->set_count], 0, sizeof(byteset));
    return ps->set_count++;
}

static void set_add(byteset *s, int c) {
    s->bits[(unsigned char)c >> 3] |= (uint8_t)(1 << (c & 7));
}

static int set_has(const byteset *s, int c) {
    return (s->bits[(unsigned char)c >> 3] >> (c & 7)) & 1;
}

static void set_add_case(parser *ps, byteset *s, int c) {
    set_add(s, c);
    if (ps->flags & REG_ICASE) {
        set_add(s, tolower(c));
        set_add(s, toupper(c));
    }
}

static int is_word(int c) {
    return isalnum(c) || c == '_';
}

static int class_test(const char *name, size_t len, int c) {
#define CLASS(n, test) if (len == sizeof(n) - 1 && memcmp(name, n, len) == 0) return (test) != 0;
    CLASS("alpha", isalpha(c))
    CLASS("digit", isdigit(c))
    CLASS("alnum", isalnum(c))
    CLASS("upper", isupper(c))
    CLASS("lower", islower(c))
    CLASS("space", isspace(c))
    CLASS("blank", c == ' ' || c == '\t')
    CLASS("punct", ispunct(c))
    CLASS("print", isprint(c))
    CLASS("graph", isgraph(c))
    CLASS("cntrl", iscntrl(c))
    CLASS("xdigit", isxdigit(c))
#undef CLASS
    return -1;
}

/* [...] after the '[' */
static node *parse_bracket(parser *ps) {
    int index = new_set(ps);
    if (index < 0) {
        return NULL;
    }
    byteset set = {{0}};
    int negate = 0;
    if (*ps->p == '^') {
        negate = 1;
        ps->p++;
    }
    int first = 1;
    for (;;) {
        char c = *ps->p;
        if (c == '\0') {
            ps->error = REG_EBRACK;
            return NULL;
        }
        if (c == ']' && !first) {
            ps->p++;
            break;
        }
        first = 0;
        if (c == '[' && (ps->p[1] == ':' || ps->p[1] == '=' || ps->p[1] == '.')) {
            char kind = ps->p[1];
            const char *start = ps->p + 2;
            const char *end = start;
            while (*end != '\0' && !(end[0] == kind && end[1] == ']')) {
                end++;
            }
            if (*end == '\0') {
                ps->error = REG_EBRACK;
                return NULL;
            }
            size_t len = (size_t)(end - start);
            ps->p = end + 2;
            if (kind == ':') {
                if (class_test(start, len, 'a') < 0) {
                    ps->error = REG_ECTYPE;
                    return NULL;
                }
                for (int b = 1; b < 256; b++) {
                    if (class_test(start, len, b) > 0) {
                        set_add(&set, b);
                    }
                }
                if ((ps->flags & REG_ICASE) && (len == 5 && (memcmp(start, "upper", 5) == 0 || memcmp(start, "lower", 5) == 0))) {
                    for (int b = 'a'; b <= 'z'; b++) {
                        set_add(&set, b);
                        set_add(&set, b - 32);
                    }
                }
            } else {
                /* [=c=] and [.c.]: the one character */
                if (len != 1) {
                    ps->error = REG_ECOLLATE;
                    return NULL;
                }
                set_add_case(ps, &set, (unsigned char)start[0]);
            }
            continue;
        }
        int lo = (unsigned char)c;
        ps->p++;
        if (*ps->p == '-' && ps->p[1] != ']' && ps->p[1] != '\0') {
            int hi = (unsigned char)ps->p[1];
            ps->p += 2;
            if (hi < lo) {
                ps->error = REG_ERANGE;
                return NULL;
            }
            for (int b = lo; b <= hi; b++) {
                set_add_case(ps, &set, b);
            }
        } else {
            set_add_case(ps, &set, lo);
        }
    }
    if (negate) {
        for (int i = 0; i < 32; i++) {
            set.bits[i] = (uint8_t)~set.bits[i];
        }
        set.bits[0] &= (uint8_t)~1; /* never NUL */
        if (ps->flags & REG_NEWLINE) {
            set.bits['\n' >> 3] &= (uint8_t)~(1 << ('\n' & 7));
        }
    }
    ps->sets[index] = set;
    node *n = new_node(ps, N_SET);
    if (n != NULL) {
        n->value = index;
    }
    return n;
}

static node *parse_alt(parser *ps, int depth);

static node *char_node(parser *ps, int c) {
    if ((ps->flags & REG_ICASE) && isalpha(c)) {
        int index = new_set(ps);
        if (index < 0) {
            return NULL;
        }
        set_add_case(ps, &ps->sets[index], c);
        node *n = new_node(ps, N_SET);
        if (n != NULL) {
            n->value = index;
        }
        return n;
    }
    node *n = new_node(ps, N_CHAR);
    if (n != NULL) {
        n->value = c;
    }
    return n;
}

/* \w \W \s \S as sets */
static node *class_escape(parser *ps, int word, int negate) {
    int index = new_set(ps);
    if (index < 0) {
        return NULL;
    }
    for (int b = 1; b < 256; b++) {
        int in = word ? is_word(b) : isspace(b) != 0;
        if (in != negate) {
            set_add(&ps->sets[index], b);
        }
    }
    node *n = new_node(ps, N_SET);
    if (n != NULL) {
        n->value = index;
    }
    return n;
}

/* One atom, or NULL with no error at the end of a branch */
static node *parse_atom(parser *ps, int depth, int branch_start) {
    int ere = ps->flags & REG_EXTENDED;
    char c = *ps->p;
    if (c == '\0') {
        return NULL;
    }
    if (ere) {
        if (c == '|' || c == ')') {
            return NULL;
        }
        if (c == '(') {
            ps->p++;
            int group = ++ps->groups;
            node *inner = parse_alt(ps, depth + 1);
            if (ps->error) {
                return NULL;
            }
            if (*ps->p != ')') {
                ps->error = REG_EPAREN;
                return NULL;
            }
            ps->p++;
            node *n = new_node(ps, N_GROUP);
            if (n != NULL) {
                n->value = group;
                n->a = inner;
            }
            return n;
        }
        if ((c == '*' || c == '+' || c == '?') && branch_start) {
            ps->error = REG_BADRPT;
            return NULL;
        }
        if (c == '{' && branch_start && isdigit((unsigned char)ps->p[1])) {
            ps->error = REG_BADRPT;
            return NULL;
        }
    } else {
        if (c == '\\' && (ps->p[1] == '|' || ps->p[1] == ')')) {
            return NULL;
        }
        if (c == '\\' && ps->p[1] == '(') {
            ps->p += 2;
            int group = ++ps->groups;
            node *inner = parse_alt(ps, depth + 1);
            if (ps->error) {
                return NULL;
            }
            if (ps->p[0] != '\\' || ps->p[1] != ')') {
                ps->error = REG_EPAREN;
                return NULL;
            }
            ps->p += 2;
            node *n = new_node(ps, N_GROUP);
            if (n != NULL) {
                n->value = group;
                n->a = inner;
            }
            return n;
        }
        if (c == '*' && branch_start) { /* a literal * at the start (BRE) */
            ps->p++;
            return char_node(ps, '*');
        }
    }
    if (c == '^' && (ere || branch_start)) {
        ps->p++;
        return new_node(ps, N_BOL);
    }
    if (c == '$') {
        /* BRE: an anchor only at the end of a branch */
        const char *next = ps->p + 1;
        if (ere || *next == '\0' || (next[0] == '\\' && (next[1] == ')' || next[1] == '|'))) {
            ps->p++;
            return new_node(ps, N_EOL);
        }
    }
    if (c == '.') {
        ps->p++;
        return new_node(ps, N_ANY);
    }
    if (c == '[') {
        ps->p++;
        return parse_bracket(ps);
    }
    if (c == '\\') {
        char e = ps->p[1];
        if (e == '\0') {
            ps->error = REG_EESCAPE;
            return NULL;
        }
        ps->p += 2;
        if (e >= '1' && e <= '9') {
            if (e - '0' > ps->groups) {
                ps->error = REG_ESUBREG;
                return NULL;
            }
            node *n = new_node(ps, N_BACKREF);
            if (n != NULL) {
                n->value = e - '0';
            }
            return n;
        }
        switch (e) {
            case 'w': return class_escape(ps, 1, 0);
            case 'W': return class_escape(ps, 1, 1);
            case 's': return class_escape(ps, 0, 0);
            case 'S': return class_escape(ps, 0, 1);
            case 'b': return new_node(ps, N_WORDB);
            case 'B': return new_node(ps, N_NWORDB);
            case '<': return new_node(ps, N_WBEG);
            case '>': return new_node(ps, N_WEND);
            case '`': return new_node(ps, N_BOL);
            case '\'': return new_node(ps, N_EOL);
            case 'n': return char_node(ps, '\n');
            case 't': return char_node(ps, '\t');
            default: return char_node(ps, (unsigned char)e);
        }
    }
    ps->p++;
    return char_node(ps, (unsigned char)c);
}

/* {m}, {m,}, {m,n} after the '{' (BRE: after "\{") */
static int parse_bounds(parser *ps, int *min, int *max) {
    int ere = ps->flags & REG_EXTENDED;
    if (!isdigit((unsigned char)*ps->p)) {
        return REG_BADBR;
    }
    long m = strtol(ps->p, (char **)&ps->p, 10);
    long n = m;
    if (*ps->p == ',') {
        ps->p++;
        n = isdigit((unsigned char)*ps->p) ? strtol(ps->p, (char **)&ps->p, 10) : -1;
    }
    if (ere ? *ps->p != '}' : (ps->p[0] != '\\' || ps->p[1] != '}')) {
        return REG_EBRACE;
    }
    ps->p += ere ? 1 : 2;
    if (m > 255 || n > 255 || (n >= 0 && n < m)) {
        return REG_BADBR;
    }
    *min = (int)m;
    *max = (int)n;
    return 0;
}

static node *parse_piece(parser *ps, int depth, int branch_start) {
    node *atom = parse_atom(ps, depth, branch_start);
    if (atom == NULL || ps->error) {
        return NULL;
    }
    int ere = ps->flags & REG_EXTENDED;
    for (;;) {
        int min, max;
        char c = *ps->p;
        if (c == '*') {
            ps->p++;
            min = 0;
            max = -1;
        } else if (ere && c == '+') {
            ps->p++;
            min = 1;
            max = -1;
        } else if (ere && c == '?') {
            ps->p++;
            min = 0;
            max = 1;
        } else if (!ere && c == '\\' && ps->p[1] == '+') {
            ps->p += 2;
            min = 1;
            max = -1;
        } else if (!ere && c == '\\' && ps->p[1] == '?') {
            ps->p += 2;
            min = 0;
            max = 1;
        } else if (ere && c == '{' && isdigit((unsigned char)ps->p[1])) {
            ps->p++;
            if ((ps->error = parse_bounds(ps, &min, &max)) != 0) {
                return NULL;
            }
        } else if (!ere && c == '\\' && ps->p[1] == '{') {
            ps->p += 2;
            if ((ps->error = parse_bounds(ps, &min, &max)) != 0) {
                return NULL;
            }
        } else {
            return atom;
        }
        if (atom->type == N_BOL || atom->type == N_EOL) {
            continue; /* a repeated anchor is the anchor */
        }
        node *r = new_node(ps, N_REPEAT);
        if (r == NULL) {
            return NULL;
        }
        r->a = atom;
        r->min = min;
        r->max = max;
        atom = r;
    }
}

static node *parse_branch(parser *ps, int depth) {
    node *result = NULL;
    int start = 1;
    for (;;) {
        node *piece = parse_piece(ps, depth, start);
        if (ps->error) {
            return NULL;
        }
        if (piece == NULL) {
            break;
        }
        start = 0;
        if (result == NULL) {
            result = piece;
        } else {
            node *cat = new_node(ps, N_CAT);
            if (cat == NULL) {
                return NULL;
            }
            cat->a = result;
            cat->b = piece;
            result = cat;
        }
    }
    return result != NULL ? result : new_node(ps, N_EMPTY);
}

static node *parse_alt(parser *ps, int depth) {
    if (depth > 100) {
        ps->error = REG_ESPACE;
        return NULL;
    }
    node *left = parse_branch(ps, depth);
    int ere = ps->flags & REG_EXTENDED;
    while (!ps->error && (ere ? *ps->p == '|' : (ps->p[0] == '\\' && ps->p[1] == '|'))) {
        ps->p += ere ? 1 : 2;
        node *right = parse_branch(ps, depth);
        if (ps->error) {
            return NULL;
        }
        node *alt = new_node(ps, N_ALT);
        if (alt == NULL) {
            return NULL;
        }
        alt->a = left;
        alt->b = right;
        left = alt;
    }
    return left;
}

/* THE PROGRAM */

enum { I_CHAR, I_ANY, I_SET, I_BOL, I_EOL, I_WORDB, I_NWORDB, I_WBEG, I_WEND, I_SPLIT, I_JMP, I_SAVE, I_MARK, I_CHECK,
       I_BACKREF, I_MATCH };

typedef struct {
    uint8_t op;
    int x, y; /* CHAR: byte; SET: set; SPLIT: first, second; JMP: target; SAVE, MARK, CHECK, BACKREF: slot */
} inst;

typedef struct {
    inst *code;
    int len, cap;
    int marks; /* loop marks used */
    int error;
} emitter;

typedef struct {
    inst *code;
    int len;
    byteset *sets;
    int marks;
    int groups;
    int flags;
    int anchored; /* starts with ^ and REG_NEWLINE is off: only at the text's start */
} program;

static int emit(emitter *e, int op, int x, int y) {
    if (e->len == e->cap) {
        int cap = e->cap * 2 + 64;
        if (cap > MAX_PROG) {
            e->error = REG_ESPACE;
            return -1;
        }
        inst *c = realloc(e->code, (size_t)cap * sizeof(inst));
        if (c == NULL) {
            e->error = REG_ESPACE;
            return -1;
        }
        e->code = c;
        e->cap = cap;
    }
    e->code[e->len] = (inst){(uint8_t)op, x, y};
    return e->len++;
}

static void gen(emitter *e, const node *n);

/* n repeated without limit: L: SPLIT body, out; body: MARK k; n; CHECK k (no
   endless loops on empty matches); JMP L */
static void gen_star(emitter *e, const node *n) {
    int mark = e->marks++;
    int split = emit(e, I_SPLIT, 0, 0);
    if (split < 0) {
        return;
    }
    e->code[split].x = e->len;
    emit(e, I_MARK, mark, 0);
    gen(e, n);
    emit(e, I_CHECK, mark, 0);
    emit(e, I_JMP, split, 0);
    if (!e->error) {
        e->code[split].y = e->len;
    }
}

static void gen(emitter *e, const node *n) {
    if (e->error || n == NULL) {
        return;
    }
    switch (n->type) {
        case N_CHAR: emit(e, I_CHAR, n->value, 0); break;
        case N_ANY: emit(e, I_ANY, 0, 0); break;
        case N_SET: emit(e, I_SET, n->value, 0); break;
        case N_BOL: emit(e, I_BOL, 0, 0); break;
        case N_EOL: emit(e, I_EOL, 0, 0); break;
        case N_WORDB: emit(e, I_WORDB, 0, 0); break;
        case N_NWORDB: emit(e, I_NWORDB, 0, 0); break;
        case N_WBEG: emit(e, I_WBEG, 0, 0); break;
        case N_WEND: emit(e, I_WEND, 0, 0); break;
        case N_EMPTY: break;
        case N_BACKREF: emit(e, I_BACKREF, n->value, 0); break;
        case N_GROUP:
            emit(e, I_SAVE, 2 * n->value, 0);
            gen(e, n->a);
            emit(e, I_SAVE, 2 * n->value + 1, 0);
            break;
        case N_CAT:
            gen(e, n->a);
            gen(e, n->b);
            break;
        case N_ALT: {
            int split = emit(e, I_SPLIT, 0, 0);
            if (split < 0) {
                return;
            }
            e->code[split].x = e->len;
            gen(e, n->a);
            int jmp = emit(e, I_JMP, 0, 0);
            if (jmp < 0) {
                return;
            }
            e->code[split].y = e->len;
            gen(e, n->b);
            e->code[jmp].x = e->len;
            break;
        }
        case N_REPEAT: {
            for (int i = 0; i < n->min; i++) {
                gen(e, n->a);
            }
            if (n->max < 0) {
                gen_star(e, n->a);
            } else {
                /* The optional ones: SPLIT body, end, nested */
                int pending[256];
                int count = 0;
                for (int i = n->min; i < n->max && !e->error; i++) {
                    int split = emit(e, I_SPLIT, 0, 0);
                    if (split < 0) {
                        return;
                    }
                    e->code[split].x = e->len;
                    pending[count++] = split;
                    gen(e, n->a);
                }
                for (int i = 0; i < count && !e->error; i++) {
                    e->code[pending[i]].y = e->len;
                }
            }
            break;
        }
    }
}

int regcomp(regex_t *re, const char *pattern, int flags) {
    parser ps = {0};
    ps.p = pattern;
    ps.flags = flags;
    ps.node_cap = (int)strlen(pattern) * 3 + 16; /* each pattern byte makes at most 3 nodes */
    ps.nodes = malloc((size_t)ps.node_cap * sizeof(node));
    if (ps.nodes == NULL) {
        return REG_ESPACE;
    }
    node *tree = parse_alt(&ps, 0);
    if (!ps.error && *ps.p != '\0') {
        ps.error = (flags & REG_EXTENDED) ? REG_EPAREN : REG_EPAREN; /* a stray ')' or "\)" */
    }
    if (!ps.error && ps.groups >= MAX_GROUPS) {
        ps.error = REG_ESPACE;
    }
    emitter e = {0};
    if (!ps.error) {
        emit(&e, I_SAVE, 0, 0);
        gen(&e, tree);
        emit(&e, I_SAVE, 1, 0);
        emit(&e, I_MATCH, 0, 0);
        ps.error = e.error;
    }
    free(ps.nodes);
    program *prog = ps.error ? NULL : malloc(sizeof(program));
    if (prog == NULL) {
        free(e.code);
        free(ps.sets);
        return ps.error ? ps.error : REG_ESPACE;
    }
    prog->code = e.code;
    prog->len = e.len;
    prog->sets = ps.sets;
    prog->marks = e.marks;
    prog->groups = ps.groups;
    prog->flags = flags;
    prog->anchored = e.len > 1 && e.code[1].op == I_BOL && !(flags & REG_NEWLINE);
    re->re_nsub = (size_t)ps.groups;
    re->re_prog = prog;
    re->re_flags = flags;
    return 0;
}

void regfree(regex_t *re) {
    program *prog = re->re_prog;
    if (prog != NULL) {
        free(prog->code);
        free(prog->sets);
        free(prog);
        re->re_prog = NULL;
    }
}

/* RUNNING IT */

enum { B_BRANCH, B_SAVE, B_MARK };

typedef struct {
    uint8_t kind;
    int a;          /* BRANCH: pc; SAVE, MARK: slot */
    regoff_t b;     /* BRANCH: position; SAVE, MARK: the old value */
} backtrack;

typedef struct {
    const program *prog;
    const char *text;
    regoff_t len;
    int eflags;
    regoff_t *slots; /* 2 per group, group 0 the whole match */
    regoff_t *marks;
    regoff_t *best;
    regoff_t best_end;
    backtrack *stack;
    size_t depth, cap;
    long steps;
} matcher;

static int push(matcher *m, int kind, int a, regoff_t b) {
    if (m->depth == m->cap) {
        size_t cap = m->cap * 2 + 256;
        backtrack *s = realloc(m->stack, cap * sizeof(backtrack));
        if (s == NULL) {
            return 0;
        }
        m->stack = s;
        m->cap = cap;
    }
    m->stack[m->depth++] = (backtrack){(uint8_t)kind, a, b};
    return 1;
}

static int word_at(const matcher *m, regoff_t i) {
    return i >= 0 && i < m->len && is_word((unsigned char)m->text[i]);
}

static int at_bol(const matcher *m, regoff_t sp) {
    if (sp == 0) {
        return !(m->eflags & REG_NOTBOL);
    }
    return (m->prog->flags & REG_NEWLINE) && m->text[sp - 1] == '\n';
}

static int at_eol(const matcher *m, regoff_t sp) {
    if (sp == m->len) {
        return !(m->eflags & REG_NOTEOL);
    }
    return (m->prog->flags & REG_NEWLINE) && m->text[sp] == '\n';
}

/* The bytes of the UTF-8 character at sp (1 for a stray byte) */
static regoff_t char_len(const matcher *m, regoff_t sp) {
    unsigned char b = (unsigned char)m->text[sp];
    regoff_t n = b < 0xC0 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
    if (sp + n > m->len) {
        return 1;
    }
    for (regoff_t i = 1; i < n; i++) {
        if (((unsigned char)m->text[sp + i] & 0xC0) != 0x80) {
            return 1;
        }
    }
    return n;
}

/* Matches starting at start; 1 if any (m->best has the longest) */
static int run(matcher *m, regoff_t start) {
    const program *prog = m->prog;
    int nslots = 2 * (prog->groups + 1);
    for (int i = 0; i < nslots; i++) {
        m->slots[i] = -1;
    }
    m->best_end = -1;
    m->depth = 0;
    int pc = 0;
    regoff_t sp = start;
    for (;;) {
        if (++m->steps > MAX_STEPS) {
            return m->best_end >= 0;
        }
        const inst *in = &prog->code[pc];
        int ok = 1;
        switch (in->op) {
            case I_CHAR:
                if (sp < m->len && (unsigned char)m->text[sp] == in->x) {
                    sp++;
                    pc++;
                } else {
                    ok = 0;
                }
                break;
            case I_ANY:
                if (sp < m->len && m->text[sp] != '\0' && !((prog->flags & REG_NEWLINE) && m->text[sp] == '\n')) {
                    sp += char_len(m, sp);
                    pc++;
                } else {
                    ok = 0;
                }
                break;
            case I_SET:
                if (sp < m->len && set_has(&prog->sets[in->x], (unsigned char)m->text[sp])) {
                    sp++;
                    pc++;
                } else {
                    ok = 0;
                }
                break;
            case I_BOL: ok = at_bol(m, sp); pc++; break;
            case I_EOL: ok = at_eol(m, sp); pc++; break;
            case I_WORDB: ok = word_at(m, sp - 1) != word_at(m, sp); pc++; break;
            case I_NWORDB: ok = word_at(m, sp - 1) == word_at(m, sp); pc++; break;
            case I_WBEG: ok = !word_at(m, sp - 1) && word_at(m, sp); pc++; break;
            case I_WEND: ok = word_at(m, sp - 1) && !word_at(m, sp); pc++; break;
            case I_SPLIT:
                if (!push(m, B_BRANCH, in->y, sp)) {
                    return m->best_end >= 0;
                }
                pc = in->x;
                break;
            case I_JMP: pc = in->x; break;
            case I_SAVE:
                if (!push(m, B_SAVE, in->x, m->slots[in->x])) {
                    return m->best_end >= 0;
                }
                m->slots[in->x] = sp;
                pc++;
                break;
            case I_MARK:
                if (!push(m, B_MARK, in->x, m->marks[in->x])) {
                    return m->best_end >= 0;
                }
                m->marks[in->x] = sp;
                pc++;
                break;
            case I_CHECK: ok = m->marks[in->x] != sp; pc++; break;
            case I_BACKREF: {
                regoff_t so = m->slots[2 * in->x], eo = m->slots[2 * in->x + 1];
                if (so < 0 || eo < so) {
                    ok = 0;
                    break;
                }
                regoff_t n = eo - so;
                if (sp + n > m->len) {
                    ok = 0;
                    break;
                }
                for (regoff_t i = 0; i < n && ok; i++) {
                    int a = (unsigned char)m->text[so + i], b = (unsigned char)m->text[sp + i];
                    ok = (prog->flags & REG_ICASE) ? tolower(a) == tolower(b) : a == b;
                }
                if (ok) {
                    sp += n;
                    pc++;
                }
                break;
            }
            case I_MATCH:
                if (sp > m->best_end) {
                    m->best_end = sp;
                    memcpy(m->best, m->slots, (size_t)nslots * sizeof(regoff_t));
                    if (sp == m->len) {
                        return 1; /* nothing can be longer */
                    }
                }
                ok = 0; /* go on: a longer match may follow */
                break;
        }
        if (ok) {
            continue;
        }
        /* Back to the last branch, undoing saves and marks on the way */
        for (;;) {
            if (m->depth == 0) {
                return m->best_end >= 0;
            }
            backtrack *b = &m->stack[--m->depth];
            if (b->kind == B_SAVE) {
                m->slots[b->a] = b->b;
            } else if (b->kind == B_MARK) {
                m->marks[b->a] = b->b;
            } else {
                pc = b->a;
                sp = b->b;
                break;
            }
        }
    }
}

int regexec(const regex_t *re, const char *text, size_t nmatch, regmatch_t pmatch[], int eflags) {
    const program *prog = re->re_prog;
    if (prog == NULL) {
        return REG_BADPAT;
    }
    regoff_t from = 0;
    regoff_t len = (regoff_t)strlen(text);
    if ((eflags & REG_STARTEND) && pmatch != NULL) {
        from = pmatch[0].rm_so;
        len = pmatch[0].rm_eo;
    }
    int nslots = 2 * (prog->groups + 1);
    matcher m = {0};
    m.prog = prog;
    m.text = text;
    m.len = len;
    m.eflags = eflags;
    m.slots = malloc((size_t)nslots * 2 * sizeof(regoff_t) + (size_t)(prog->marks + 1) * sizeof(regoff_t));
    if (m.slots == NULL) {
        return REG_ESPACE;
    }
    m.best = m.slots + nslots;
    m.marks = m.best + nslots;
    for (int i = 0; i < prog->marks; i++) {
        m.marks[i] = -1;
    }
    int found = 0;
    for (regoff_t start = from; start <= len; start++) {
        if (run(&m, start)) {
            found = 1;
            break;
        }
        if (prog->anchored || m.steps > MAX_STEPS) {
            break;
        }
    }
    if (found && !(re->re_flags & REG_NOSUB) && pmatch != NULL) {
        for (size_t i = 0; i < nmatch; i++) {
            if ((int)i <= prog->groups && m.best[2 * i] >= 0 && m.best[2 * i + 1] >= m.best[2 * i]) {
                pmatch[i].rm_so = m.best[2 * i];
                pmatch[i].rm_eo = m.best[2 * i + 1];
            } else {
                pmatch[i].rm_so = -1;
                pmatch[i].rm_eo = -1;
            }
        }
    }
    free(m.slots);
    free(m.stack);
    return found ? 0 : REG_NOMATCH;
}

size_t regerror(int code, const regex_t *re, char *buf, size_t size) {
    (void)re;
    static const char *const texts[] = {
        "Success", "No match", "Invalid regular expression", "Invalid collation character",
        "Invalid character class name", "Trailing backslash", "Invalid back reference", "Unmatched [ or [^",
        "Unmatched ( or \\(", "Unmatched \\{", "Invalid content of \\{\\}", "Invalid range end",
        "Memory exhausted", "Invalid preceding regular expression",
    };
    const char *t = code >= 0 && code < (int)(sizeof(texts) / sizeof(texts[0])) ? texts[code] : "Unknown error";
    size_t n = strlen(t) + 1;
    if (size > 0) {
        size_t copy = n < size ? n : size;
        memcpy(buf, t, copy - 1);
        buf[copy - 1] = '\0';
    }
    return n;
}
