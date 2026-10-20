#include "COnigBridge.h"
#include <oniguruma.h>
#include <pthread.h>
#include <stdlib.h>
struct MPScanner { OnigRegSet *set; OnigMatchParam *params[512]; int count; };
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { OnigEncoding encodings[] = { ONIG_ENCODING_UTF8 }; onig_initialize(encodings,1); }
MPScanner *mp_scanner_new(void) {
    pthread_once(&once,initialize);
    MPScanner *s=calloc(1,sizeof(MPScanner));if (!s) return NULL;
    if (onig_regset_new(&s->set,0,NULL) != ONIG_NORMAL) { free(s);return NULL; } return s;
}
int32_t mp_scanner_add(MPScanner *s,const uint8_t *pattern,int32_t length) {
    if (!s || length < 0 || length > 16384 || s->count >= 512) return -10001;
    OnigRegex regex;OnigErrorInfo error;
    int result=onig_new(&regex,pattern,pattern+length,ONIG_OPTION_CAPTURE_GROUP,ONIG_ENCODING_UTF8,ONIG_SYNTAX_DEFAULT,&error);
    if (result != ONIG_NORMAL) return result;
    OnigMatchParam *param=onig_new_match_param();if (!param) { onig_free(regex);return -10002; }
    onig_set_match_stack_limit_size_of_match_param(param,1<<20);
    onig_set_retry_limit_in_match_of_match_param(param,100000);
    onig_set_retry_limit_in_search_of_match_param(param,200000);
    result=onig_regset_add(s->set,regex);
    if (result != ONIG_NORMAL) { onig_free_match_param(param);onig_free(regex);return result; }
    s->params[s->count++]=param;return 0;
}
int32_t mp_scanner_search(MPScanner *s,const uint8_t *text,int32_t length,int32_t start,int32_t flags,MPCapture *captures,int32_t capacity,int32_t *count) {
    if (!s || length < 0 || length > 131072 || start < 0 || start > length) return -10003;
    if (s->count == 0) return -1;
    OnigOptionType options=ONIG_OPTION_NONE;
    if (flags & 1) options |= ONIG_OPTION_NOT_BEGIN_STRING;
    if (flags & 2) options |= ONIG_OPTION_NOT_END_STRING;
    if (flags & 4) options |= ONIG_OPTION_NOT_BEGIN_POSITION;
    int position=0;
    int index=onig_regset_search_with_param(s->set,text,text+length,text+start,text+length,ONIG_REGSET_POSITION_LEAD,options,s->params,&position);
    if (index < 0) return index;
    OnigRegion *region=onig_regset_get_region(s->set,index);
    if (!region || region->num_regs > capacity) return -10004;
    *count=region->num_regs;
    for (int i=0;i<*count;i++) { captures[i].start=region->beg[i];captures[i].end=region->end[i]; }
    return index;
}
void mp_scanner_free(MPScanner *s) {
    if (!s) return;
    for (int i=0;i<s->count;i++) onig_free_match_param(s->params[i]);
    onig_regset_free(s->set);free(s);
}
