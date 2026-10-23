#ifndef VORTX_SMB_SHIM_H
#define VORTX_SMB_SHIM_H

// The few libsmbclient calls VortX's network-share browser makes, declared here rather than imported.
//
// The app already links Samba's libsmbclient through MPVKit-GPL (its FFmpeg is built with
// --enable-libsmbclient, which is what lets the player open smb:// files). The framework's module map
// umbrellas every Samba header, several of which need talloc.h and do not compile on their own, so
// `import Libsmbclient` fails. These declarations are copied verbatim from Samba 4.15.13's public
// libsmbclient.h (the pinned Libsmbclient.xcframework); scripts/test-network-shares.sh checks each one
// against that header so a library bump cannot drift silently.

typedef struct _SMBCCTX SMBCCTX;
typedef struct _SMBCFILE SMBCFILE;
typedef int smbc_bool;

struct smbc_dirent
{
	unsigned int smbc_type;
	unsigned int dirlen;
	unsigned int commentlen;
	char *comment;
	unsigned int namelen;
	char name[1];
};

typedef void (*smbc_get_auth_data_with_context_fn)(SMBCCTX *c,
                                                   const char *srv,
                                                   const char *shr,
                                                   char *wg, int wglen,
                                                   char *un, int unlen,
                                                   char *pw, int pwlen);
typedef SMBCFILE * (*smbc_opendir_fn)(SMBCCTX *c,
                                      const char *fname);
typedef int (*smbc_closedir_fn)(SMBCCTX *c,
                                SMBCFILE *dir);
typedef struct smbc_dirent * (*smbc_readdir_fn)(SMBCCTX *c,
                                                SMBCFILE *dir);

SMBCCTX * smbc_new_context(void);
SMBCCTX * smbc_init_context(SMBCCTX * context);
int smbc_free_context(SMBCCTX * context, int shutdown_ctx);
void smbc_setTimeout(SMBCCTX *c, int timeout);
void * smbc_getOptionUserData(SMBCCTX *c);
void smbc_setOptionUserData(SMBCCTX *c, void *user_data);
void smbc_setOptionNoAutoAnonymousLogin(SMBCCTX *c, smbc_bool b);
void smbc_setFunctionAuthDataWithContext(SMBCCTX *c, smbc_get_auth_data_with_context_fn fn);
smbc_opendir_fn smbc_getFunctionOpendir(SMBCCTX *c);
smbc_closedir_fn smbc_getFunctionClosedir(SMBCCTX *c);
smbc_readdir_fn smbc_getFunctionReaddir(SMBCCTX *c);

#endif
