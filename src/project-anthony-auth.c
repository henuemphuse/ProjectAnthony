/*
 * Verify a local account password via PAM (service: project-anthony).
 * Usage: project-anthony-auth <username>
 * Password is read from stdin (one line). Exit 0 on success, 1 on failure.
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
#define PAM_BUF_ERR 5

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

static void wipe(void *p, size_t n)
{
    explicit_bzero(p, n);
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
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
            msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
            r[i].resp = strdup(g_pass ? g_pass : "");
            if (!r[i].resp) {
                int j;
                for (j = 0; j < i; j++)
                    free(r[j].resp);
                free(r);
                return PAM_BUF_ERR;
            }
        }
    }
    *resp = r;
    return PAM_SUCCESS;
}

int main(int argc, char **argv)
{
    char buf[256];
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = { conv_cb, NULL };
    int rc;

    if (argc != 2 || argv[1][0] == '\0')
        return 2;
    if (!fgets(buf, (int)sizeof(buf), stdin))
        return 1;
    buf[strcspn(buf, "\n")] = '\0';
    g_pass = buf;

    rc = pam_start("project-anthony", argv[1], &conv, &pamh);
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
