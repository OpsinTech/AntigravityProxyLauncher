#include <arpa/inet.h>
#include <poll.h>
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <unordered_map>

#include <netinet/in.h>
#include <string>
#include <sys/socket.h>

#include "Config.hpp"
#include "FakeIP.hpp"
#include "Logger.hpp"
#include "Socks5.hpp"
#include "interpose.h"
#include <Security/Security.h>
#include <mach-o/dyld.h>
#include <algorithm>

// Check if the current app should be intercepted for MITM
static bool IsAppAllowedForMitm() {
    char path[1024];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        std::string execPath(path);
        std::string lowerPath = execPath;
        std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
        // User requested: prioritize antigravity and antigravity ide
        if (lowerPath.find("antigravity") != std::string::npos) {
            return true;
        }
    }
    return false;
}

// Thread-safe map to store sockfd -> original FakeIP address mapping
static std::mutex g_sockfd_map_mtx;
static std::unordered_map<int, struct sockaddr_storage> g_sockfd_map;
static std::unordered_map<int, socklen_t> g_sockfd_len_map;

int my_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
  if (!addr)
    return connect(sockfd, addr, addrlen);

  // 初始化配置（仅执行一次）
  static bool init = []() {
    Core::Logger::Init("/tmp/antigravity_proxy.log");
    Core::Config::Instance().Load();
    return true;
  }();
  (void)init;

  uint32_t ip = 0;
  uint16_t port = 0;
  bool is_ipv4 = false;

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    ip = sin->sin_addr.s_addr;
    port = ntohs(sin->sin_port);
    is_ipv4 = true;
  } else if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    if (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr)) {
      memcpy(&ip, &sin6->sin6_addr.s6_addr[12], 4);
      port = ntohs(sin6->sin6_port);
      is_ipv4 = true;
    }
  }

  // 处理 IPv4 目标地址，或 IPv4-Mapped IPv6
  if (is_ipv4) {
    // 检查是否为 FakeIP
    if (Network::FakeIP::Instance().IsFakeIP(ip)) {
      std::string domain = Network::FakeIP::Instance().GetDomain(ip);
      if (!domain.empty()) {
        Core::Logger::Info("Hook: connect to FakeIP " + domain +
                           " (Orig: " + domain + ")");

        auto &config = Core::Config::Instance();

        bool isMitmDomain = false;
        
        // Only map if it's the target app AND model routing is explicitly enabled in config
        if (config.mitm.model_routing_enabled && IsAppAllowedForMitm()) {
            isMitmDomain = (domain.find("anthropic.com") != std::string::npos ||
                            domain.find("deepseek.com") != std::string::npos ||
                            domain.find("generativelanguage.googleapis.com") != std::string::npos ||
                            domain.find("cloudcode-pa.googleapis.com") != std::string::npos);
        }
                             
        int targetPort = isMitmDomain ? 8081 : config.proxy.port;
        std::string targetHost = isMitmDomain ? "127.0.0.1" : config.proxy.host;
        
        if (isMitmDomain) {
            Core::Logger::Info("Hook: Routing AI domain " + domain + " to local MITM proxy at " + targetHost + ":" + std::to_string(targetPort));
        }

        // 优化：用 getsockopt 判断 socket 类型，避免试错 connect
        // 尝试获取 IPV6_V6ONLY 选项，如果成功说明是 IPv6 socket
        int v6only = 0;
        socklen_t optlen = sizeof(v6only);
        bool isIpv6Socket = (getsockopt(sockfd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, &optlen) == 0);
        
        int res = -1;
        int saved_errno = 0;
        
        if (isIpv6Socket) {
          // IPv6 socket：解析配置的 proxy.host
          struct sockaddr_in6 proxyAddr6;
          memset(&proxyAddr6, 0, sizeof(proxyAddr6));
          proxyAddr6.sin6_family = AF_INET6;
          proxyAddr6.sin6_port = htons(targetPort);
          
          // 首先尝试解析为真正的 IPv6 地址
          if (inet_pton(AF_INET6, targetHost.c_str(), &proxyAddr6.sin6_addr) != 1) {
            // 如果解析失败，尝试解析为 IPv4 地址，并转化为 IPv4-Mapped IPv6 (::ffff:x.x.x.x)
            struct in_addr ipv4;
            if (inet_pton(AF_INET, targetHost.c_str(), &ipv4) == 1) {
              proxyAddr6.sin6_addr.s6_addr[10] = 0xff;
              proxyAddr6.sin6_addr.s6_addr[11] = 0xff;
              memcpy(&proxyAddr6.sin6_addr.s6_addr[12], &ipv4.s_addr, 4);
            } else {
              Core::Logger::Error("Invalid Proxy IP for IPv6 Socket: " + targetHost);
              errno = EINVAL;
              return -1;
            }
          }
          
          Core::Logger::Debug("Connecting to Proxy (IPv6/Mapped): " + targetHost + ":" + std::to_string(targetPort));
          res = connect(sockfd, (struct sockaddr *)&proxyAddr6, sizeof(proxyAddr6));
          saved_errno = errno;
        } else {
          // IPv4 socket：使用 127.0.0.1:port
          struct sockaddr_in proxyAddr;
          memset(&proxyAddr, 0, sizeof(proxyAddr));
          proxyAddr.sin_family = AF_INET;
          proxyAddr.sin_port = htons(targetPort);
          if (inet_pton(AF_INET, targetHost.c_str(), &proxyAddr.sin_addr) != 1) {
            Core::Logger::Error("Invalid Proxy IP: " + targetHost);
            errno = EINVAL;
            return -1;
          }
          Core::Logger::Debug("Connecting to " + targetHost + ":" + 
                             std::to_string(targetPort));
          res = connect(sockfd, (struct sockaddr *)&proxyAddr, sizeof(proxyAddr));
          saved_errno = errno;
        }
        
        if (res != 0 && saved_errno != EINPROGRESS) {
          Core::Logger::Error("Connect failed, errno=" + std::to_string(saved_errno));
        }
        if (res != 0) {
          if (saved_errno == EINPROGRESS) {
             // 对于非阻塞 socket，我们需要等待连接完成
             // 使用 poll 替代 select，避免 FD_SETSIZE 限制
             struct pollfd pfd;
             pfd.fd = sockfd;
             pfd.events = POLLOUT;
             pfd.revents = 0;
             
             // 缩短 timeout，减少饿死 Chromium 事件循环的时间
             int timeoutMs = std::min(config.timeout.connect_ms, 2000);
             int pollRes = -1;
             
             // 带 EINTR 重试的 poll
             do {
               pollRes = poll(&pfd, 1, timeoutMs);
             } while (pollRes == -1 && errno == EINTR);
             
             if (pollRes > 0) {
                // 检查是否有错误
                int so_error;
                socklen_t len = sizeof(so_error);
                if (getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &so_error, &len) < 0) {
                    Core::Logger::Error("getsockopt failed, fd=" + std::to_string(sockfd));
                    return -1;
                }
                if (so_error != 0) {
                    Core::Logger::Error("Async connect failed, fd=" + std::to_string(sockfd) + 
                                        ", so_error=" + std::to_string(so_error));
                    errno = so_error;
                    return -1;
                }
                Core::Logger::Debug("Async connect succeeded via poll, fd=" + std::to_string(sockfd));
                // 连接成功
             } else if (pollRes == 0) {
                 Core::Logger::Error("Async connect timeout, fd=" + std::to_string(sockfd));
                 errno = ETIMEDOUT;
                 return -1;
             } else {
                 Core::Logger::Error("poll failed, fd=" + std::to_string(sockfd) + 
                                     ", errno=" + std::to_string(errno));
                 return -1;
             }
          } else {
              Core::Logger::Error("Failed to connect to proxy, fd=" + std::to_string(sockfd) + 
                                  ", errno=" + std::to_string(errno));
              return -1;
          }
        }

        bool handshakeSuccess = true;
        
        if (!isMitmDomain) {
            // SOCKS5 握手
            // 注意：Socks5Client 此时是同步阻塞实现的。
            // 如果原始 socket 是非阻塞的，我们需要临时切换为阻塞模式。
            Core::Logger::Debug("Preparing for SOCKS5 handshake, fd=" + std::to_string(sockfd));
            int flags = fcntl(sockfd, F_GETFL, 0);
            if (flags < 0) {
                Core::Logger::Error("Failed to get socket flags, fd=" + std::to_string(sockfd));
                return -1;
            }
            bool isNonBlock = (flags & O_NONBLOCK);
            Core::Logger::Debug("Socket flags=" + std::to_string(flags) + ", isNonBlock=" + std::to_string(isNonBlock));
            
            if (isNonBlock) {
                Core::Logger::Debug("Temporarily setting socket to blocking mode");
                if (fcntl(sockfd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
                    Core::Logger::Error("Failed to set blocking mode, fd=" + std::to_string(sockfd));
                    return -1;
                }
            }

            Core::Logger::Debug("Starting SOCKS5 handshake...");
            handshakeSuccess = Network::Socks5Client::Handshake(sockfd, domain, port);
            Core::Logger::Debug("SOCKS5 handshake result: " + std::string(handshakeSuccess ? "success" : "failed"));

            // 恢复原始 flags
            if (isNonBlock) {
                Core::Logger::Debug("Restoring socket to non-blocking mode");
                if (fcntl(sockfd, F_SETFL, flags) < 0) {
                    Core::Logger::Error("Failed to restore non-blocking mode, fd=" + std::to_string(sockfd));
                }
            }
        } else {
            // MITM Proxy HTTP CONNECT 握手
            Core::Logger::Debug("Preparing for HTTP CONNECT handshake, fd=" + std::to_string(sockfd));
            int flags = fcntl(sockfd, F_GETFL, 0);
            bool isNonBlock = (flags & O_NONBLOCK);
            if (isNonBlock) {
                fcntl(sockfd, F_SETFL, flags & ~O_NONBLOCK);
            }
            
            std::string req = "CONNECT " + domain + ":" + std::to_string(port) + " HTTP/1.1\r\nHost: " + domain + ":" + std::to_string(port) + "\r\n\r\n";
            send(sockfd, req.c_str(), req.length(), 0);
            char buf[1024];
            int n = recv(sockfd, buf, sizeof(buf) - 1, 0);
            if (n > 0) {
                buf[n] = '\0';
                if (strstr(buf, "HTTP/1.1 200") == nullptr && strstr(buf, "HTTP/1.0 200") == nullptr) {
                    handshakeSuccess = false;
                    Core::Logger::Error("MITM CONNECT fail " + domain + ": " + std::string(buf));
                }
            } else {
                handshakeSuccess = false;
                Core::Logger::Error("MITM CONNECT recv err " + domain + " n=" + std::to_string(n) + " errno=" + std::to_string(errno));
            }
            
            if (isNonBlock) {
                fcntl(sockfd, F_SETFL, flags);
            }
        }

        if (handshakeSuccess) {
          Core::Logger::Info("Hook: SOCKS5 tunnel established to " + domain + ":" + std::to_string(port) + ", fd=" + std::to_string(sockfd));
          
          {
            std::lock_guard<std::mutex> lock(g_sockfd_map_mtx);
            struct sockaddr_storage storage;
            memset(&storage, 0, sizeof(storage));
            memcpy(&storage, addr, addrlen);
            g_sockfd_map[sockfd] = storage;
            g_sockfd_len_map[sockfd] = addrlen;
          }
          
          return 0; // 成功建立隧道
        } else {
           Core::Logger::Error("SOCKS5 Handshake failed, fd=" + std::to_string(sockfd) + ", domain=" + domain);
           errno = ECONNREFUSED;
           return -1;
        }

      }
    }
  }

  return connect(sockfd, addr, addrlen);
}



// Hook getaddrinfo 返回 FakeIP
int my_getaddrinfo(const char *node, const char *service,
                   const struct addrinfo *hints, struct addrinfo **res) {
  auto ShouldMapAsDomain = [](const char *name) -> bool {
    if (!name || name[0] == '\0')
      return false;

    std::string host(name);
    if (host.size() > 253)
      return false;

    // 跳过明显不是域名的模式字符串或规则字符串
    static const char *kBadChars = "/*\\ <>%";
    if (host.find("://") != std::string::npos ||
        host.find_first_of(kBadChars) != std::string::npos) {
      return false;
    }

    std::string lower = host;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (lower == "localhost" || lower.rfind("localhost.", 0) == 0 ||
        lower.find(".local") != std::string::npos) {
      return false;
    }

    if (host.front() == '.' || host.back() == '.')
      return false;

    bool hasDot = false;
    bool hasAlpha = false;
    size_t labelLen = 0;
    for (char c : host) {
      if (c == '.') {
        if (labelLen == 0)
          return false;
        hasDot = true;
        labelLen = 0;
        continue;
      }
      unsigned char uc = static_cast<unsigned char>(c);
      if (!(std::isalnum(uc) || c == '-'))
        return false;
      if (std::isalpha(uc))
        hasAlpha = true;
      labelLen++;
      if (labelLen > 63)
        return false;
    }
    if (labelLen == 0)
      return false;
    if (!hasDot || !hasAlpha)
      return false;

    return true;
  };

  // 检查是否为 IP 字面量，避免递归或映射 IP
  auto IsIpLiteral = [](const char *name) -> bool {
    struct in_addr a4;
    struct in6_addr a6;
    if (inet_pton(AF_INET, name, &a4) == 1)
      return true;
    if (inet_pton(AF_INET6, name, &a6) == 1)
      return true;
    return false;
  };

  // 初始化配置
  static bool init = []() {
    Core::Logger::Init("/tmp/antigravity_proxy_loader.log");
    Core::Config::Instance().Load();
    return true;
  }();
  (void)init;

  if (hints && (hints->ai_flags & AI_NUMERICHOST)) {
    return getaddrinfo(node, service, hints, res);
  }

  if (node && Core::Config::Instance().fakeIp.enabled) {
    // 只映射合法域名，避免把 bypass 规则字符串映射成 FakeIP
    if (!IsIpLiteral(node) && ShouldMapAsDomain(node)) {
      // 分配 FakeIP
      uint32_t fakeIpNet = Network::FakeIP::Instance().Alloc(node);
      if (fakeIpNet != 0) {
        // 转换为字符串 "198.18.x.x"
        char fakeIpStr[64];
        struct in_addr in;
        in.s_addr = fakeIpNet;
        if (inet_ntop(AF_INET, &in, fakeIpStr, sizeof(fakeIpStr))) {
        Core::Logger::Info("Hook: getaddrinfo mapped " + (node ? std::string(node) : "<null>") +
                           " -> " + fakeIpStr);

          // 使用 FakeIP 调用原始 getaddrinfo
          return getaddrinfo(fakeIpStr, service, hints, res);
        }
      }
    }
  }

  return getaddrinfo(node, service, hints, res);
}

// Hook getpeername to return the original destination address (FakeIP) instead of proxy IP
int my_getpeername(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
  if (!addr || !addrlen)
    return getpeername(sockfd, addr, addrlen);
  
  {
    std::lock_guard<std::mutex> lock(g_sockfd_map_mtx);
    auto it = g_sockfd_map.find(sockfd);
    if (it != g_sockfd_map.end()) {
      socklen_t storedLen = g_sockfd_len_map[sockfd];
      size_t copyLen = (*addrlen < storedLen) ? *addrlen : storedLen;
      memcpy(addr, &it->second, copyLen);
      *addrlen = storedLen; // POSIX Requires setting it to the actual address length
      return 0; // Success
    }
  }
  
  // Fallback to system getpeername for non-tunneled sockets
  return getpeername(sockfd, addr, addrlen);
}

// Hook close to clean up our map
int my_close(int fd) {
  {
    std::lock_guard<std::mutex> lock(g_sockfd_map_mtx);
    g_sockfd_map.erase(fd);
    g_sockfd_len_map.erase(fd);
  }
  return close(fd);
}

// Hook SecTrustEvaluate for SSL Pinning Bypass
OSStatus my_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    Core::Logger::Info("Hook: SecTrustEvaluate bypassed!");
    if (result) {
        *result = kSecTrustResultProceed;
    }
    return errSecSuccess;
}

// Hook SecTrustEvaluateWithError for SSL Pinning Bypass (macOS 10.14+)
bool my_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    Core::Logger::Info("Hook: SecTrustEvaluateWithError bypassed!");
    if (error && *error) {
        // We could release it if it's set, but usually it's passed as a pointer to NULL
        *error = NULL;
    }
    return true; // true means successful evaluation
}

DYLD_INTERPOSE(my_connect, connect)
DYLD_INTERPOSE(my_getaddrinfo, getaddrinfo)
DYLD_INTERPOSE(my_getpeername, getpeername)
DYLD_INTERPOSE(my_close, close)
DYLD_INTERPOSE(my_SecTrustEvaluate, SecTrustEvaluate)
DYLD_INTERPOSE(my_SecTrustEvaluateWithError, SecTrustEvaluateWithError)

// 构造函数
__attribute__((constructor)) void LoaderInit() {
  Core::Logger::Init("/tmp/antigravity_proxy_loader.log");
  Core::Logger::Info("AntigravityTun Loaded.");
}
