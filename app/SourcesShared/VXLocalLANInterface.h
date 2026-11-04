#ifndef VX_LOCAL_LAN_INTERFACE_H
#define VX_LOCAL_LAN_INTERFACE_H

#include <fcntl.h>
#include <ifaddrs.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <unistd.h>

// Read only the fixed AF_LINK header from the same getifaddrs snapshot as the IP rows.
static inline uint32_t VortXLocalLANLinkIndex(const struct ifaddrs * _Nonnull row) {
    const struct sockaddr *address = row->ifa_addr;
    if (address == NULL || address->sa_family != AF_LINK ||
        address->sa_len < offsetof(struct sockaddr_dl, sdl_data)) {
        return 0;
    }
    return ((const struct sockaddr_dl *)address)->sdl_index;
}

// A bridge can inherit a wired functional classification from its Ethernet family.
static inline int VortXLocalLANIsBridge(const struct ifaddrs * _Nonnull row) {
    return VortXLocalLANLinkIndex(row) != 0 &&
        ((const struct sockaddr_dl *)row->ifa_addr)->sdl_type == IFT_BRIDGE;
}

// Swift does not import the ioctl request macro. A datagram descriptor is used only for the query.
// 1 means wired or infrastructure Wi-Fi, 0 means excluded, and -1 means evidence is incomplete.
static inline int VortXLocalLANClassifyLink(const struct ifaddrs * _Nonnull row) {
    const uint32_t index = VortXLocalLANLinkIndex(row);
    if (index == 0 || row->ifa_name == NULL || if_nametoindex(row->ifa_name) != index) {
        return -1;
    }
    const struct sockaddr_dl *link = (const struct sockaddr_dl *)row->ifa_addr;
    // The Ethernet link shape alone cannot establish physical media. It also excludes bridge links.
    if (link->sdl_type != IFT_ETHER) {
        return 0;
    }
    struct ifreq request = {0};
    if (strlcpy(request.ifr_name, row->ifa_name, sizeof(request.ifr_name)) >= sizeof(request.ifr_name)) {
        return -1;
    }
    const int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    const int result = fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0 ? -1 :
        ioctl(descriptor, SIOCGIFFUNCTIONALTYPE, &request);
    const int closed = close(descriptor);
    if (result < 0 || closed < 0 || if_nametoindex(row->ifa_name) != index) {
        return -1;
    }
    const uint32_t media = request.ifr_ifru.ifru_functional_type;
    if (media == IFRTYPE_FUNCTIONAL_UNKNOWN) {
        return -1;
    }
    return media == IFRTYPE_FUNCTIONAL_WIRED || media == IFRTYPE_FUNCTIONAL_WIFI_INFRA;
}

#endif
