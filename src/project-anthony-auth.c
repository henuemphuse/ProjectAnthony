/*
 * Verify TTY3 unlock via PAM.
 *   project-anthony-auth <username>       password on stdin (pam_unix)
 *   project-anthony-auth --u2f <username>  FIDO2/U2F touch (pam_u2f)
 *
 * Linked against libpam.so.0 so the package does not need libpam-dev.
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PAM_SUCCESS 0
#define PAM_PROMPT_ECHO_OFF 1
#define PAM_PROMPT_ECHO_ON 2
#define PAM_ERROR_MSG 3
#define PAM_TEXT_INFO 4
#define PAM_BUF_ERR 5
#define PAM_CONV_ERR 19

struct pam_message {
    int msg_style;
    const char *msg;
};

struct pam_response {
    char *resp;
    int resp_retcode;
};

struct pam_conv {
    int (*conv)(int num_msg, const struct pam_message **msg,
                struct pam_response **resp, void *appdata_ptr);
    void *appdata_ptr;
};

typedef struct pam_handle pam_handle_t;

int pam_start(const char *service, const char *user,
              const struct pam_conv *conv, pam_handle_t **pamh);
int pam_authenticate(pam_handle_t *pamh, int flags);
int pam_acct_mgmt(pam_handle_t *pamh, int flags);
int pam_end(pam_handle_t *pamh, int pam_status);

static char *g_pass;
static int g_u2f;

static void wipe(void *p, size_t n)
{
    explicit_bzero(p, n);
}

static void tty_msg(const char *s)
{
    FILE *t = fopen("/dev/tty", "w");

    if (!t)
        t = stderr;
    if (s && s[0]) {
        fputs(s, t);
        if (!strchr(s, '\n'))
            fputc('\n', t);
    }
    fflush(t);
    if (t != stderr)
        fclose(t);
}

static void conv_fail(struct pam_response *r, int upto)
{
    int j;

    for (j = 0; j < upto; j++)
        free(r[j].resp);
    free(r);
}

static int conv_cb(int num_msg, const struct pam_message **msg,
                   struct pam_response **resp, void *appdata_ptr)
{
    struct pam_response *r;
    int i;

    (void)appdata_ptr;
    if (num_msg <= 0)
        return PAM_BUF_ERR;
    r = calloc((size_t)num_msg, sizeof(*r));
    if (!r)
        return PAM_BUF_ERR;
    for (i = 0; i < num_msg; i++) {
        int style = msg[i]->msg_style;
        const char *text = msg[i]->msg ? msg[i]->msg : "";

        if (style == PAM_TEXT_INFO || style == PAM_ERROR_MSG) {
            tty_msg(text);
            continue;
        }
        if (style != PAM_PROMPT_ECHO_OFF && style != PAM_PROMPT_ECHO_ON) {
            conv_fail(r, i);
            return PAM_CONV_ERR;
        }
        if (g_u2f) {
            char *pin = getpass(text[0] ? text : "PIN: ");

            r[i].resp = strdup(pin ? pin : "");
            if (pin)
                wipe(pin, strlen(pin));
        } else {
            r[i].resp = strdup(g_pass ? g_pass : "");
        }
        if (!r[i].resp) {
            conv_fail(r, i);
            return PAM_BUF_ERR;
        }
    }
    *resp = r;
    return PAM_SUCCESS;
}

int main(int argc, char **argv)
{
    char buf[256];
    const char *user;
    const char *service;
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = { conv_cb, NULL };
    int rc;

    /* TTY3 already runs as root. Refuse other callers so this is not a
     * world-usable, faillock-free password oracle. */
    if (geteuid() != 0)
        return 1;

    buf[0] = '\0';
    if (argc == 3 && strcmp(argv[1], "--u2f") == 0) {
        g_u2f = 1;
        user = argv[2];
        service = "project-anthony-u2f";
    } else if (argc == 2) {
        user = argv[1];
        service = "project-anthony";
        if (!fgets(buf, (int)sizeof(buf), stdin))
            return 1;
        buf[strcspn(buf, "\n")] = '\0';
        g_pass = buf;
    } else {
        return 2;
    }
    if (!user[0])
        return 2;

    rc = pam_start(service, user, &conv, &pamh);
    if (rc == PAM_SUCCESS)
        rc = pam_authenticate(pamh, 0);
    if (rc == PAM_SUCCESS)
        rc = pam_acct_mgmt(pamh, 0);
    if (pamh)
        pam_end(pamh, rc);

    wipe(buf, sizeof(buf));
    g_pass = NULL;
    return rc == PAM_SUCCESS ? 0 : 1;
}
