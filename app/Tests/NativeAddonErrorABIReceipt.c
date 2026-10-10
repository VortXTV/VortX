#include "vortx_ffi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Synthetic loopback only. The resource-result ABI does not return configured transport URLs. */
int main(int argc, char **argv) {
    if (argc != 3 || vortx_resource_host_abi_version() != 1) return 2;
    char *end = NULL;
    long port = strtol(argv[1], &end, 10);
    if (!end || *end || port < 1 || port > 65535 ||
        (strcmp(argv[2], "401") && strcmp(argv[2], "429") && strcmp(argv[2], "503") &&
         strcmp(argv[2], "timeout") && strcmp(argv[2], "malformed"))) return 2;
    void *host = vortx_resource_host_new(), *cancel = vortx_cancel_new();
    if (!host || !cancel) return 3;
    char request[2048];
    int length = snprintf(request, sizeof request,
        "{\"requestId\":\"fixture\",\"generation\":1,\"request\":{\"resource\":\"stream\",\"type\":\"movie\",\"id\":\"fixture\"},"
        "\"addons\":[{\"id\":\"fixture\",\"transportUrl\":\"http://127.0.0.1:%ld/%s/manifest.json\","
        "\"manifest\":{\"id\":\"fixture\",\"name\":\"Fixture\",\"version\":\"1.0.0\",\"resources\":[\"stream\"],\"types\":[\"movie\"],\"catalogs\":[]}}],"
        "\"budgetMs\":250,\"maxResponseBytes\":1048576,\"maxTotalResponseBytes\":1048576}", port, argv[2]);
    if (length < 0 || length >= (int)sizeof request) { vortx_cancel_free(cancel); vortx_resource_host_free(host); return 4; }
    char *result = vortx_resource_host_load_json(host, request, cancel);
    int status = result ? 0 : 5;
    if (result) { puts(result); vortx_string_free(result); }
    vortx_cancel_free(cancel); vortx_resource_host_free(host);
    return status;
}
