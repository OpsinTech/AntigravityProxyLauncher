#pragma once

#include "Config.hpp"
#include "Logger.hpp"
#include <arpa/inet.h>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace Network {

class FakeIP {
  std::unordered_map<uint32_t, std::string> m_ipToDomain;
  std::unordered_map<std::string, uint32_t> m_domainToIp;
  std::mutex m_mtx;
  std::once_flag m_initOnce;

  uint32_t m_baseIp;
  uint32_t m_mask;
  uint32_t m_networkSize;
  uint32_t m_cursor;

  // 共享内存常量
  static constexpr uint32_t kSharedMagic = 0x4650494D; // "FIPM"
  static constexpr uint32_t kSharedCapacity = 4096;
  static constexpr size_t kSharedDomainMax = 255;
  static constexpr const char *kSharedMapName = "/antigravity_fakeip_map";

  /// 返回沙箱安全的数据目录，自动创建
  static std::string RuntimeDataDir() {
    std::string home;
    const char *envHome = getenv("HOME");
    if (envHome) {
      home = envHome;
    } else {
      struct passwd *pw = getpwuid(getuid());
      if (pw) home = pw->pw_dir;
    }
    std::string dir = home + "/.config/antigravity";
    mkdir(dir.c_str(), 0755);
    return dir;
  }

  static std::string LockFilePath() {
    return RuntimeDataDir() + "/fakeip.lock";
  }

  static std::string FallbackMapPath() {
    return RuntimeDataDir() + "/fakeip_map_" +
           std::to_string(getuid()) + ".bin";
  }

  struct SharedEntry {
    uint32_t ip;   // 主机字节序
    uint64_t tick; // 时间戳（毫秒）
    char domain[kSharedDomainMax + 1];
  };

  struct SharedTable {
    uint32_t magic;
    uint32_t capacity;
    uint32_t cursor;
    uint32_t reserved;
    SharedEntry entries[kSharedCapacity];
  };

  SharedTable *m_shared = nullptr;
  int m_lockFd = -1;
  std::once_flag m_sharedOnce;

  uint64_t GetTickCount64() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
  }

  bool LockShared() {
    if (m_lockFd == -1)
      return false;
    struct flock fl = {};
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    return fcntl(m_lockFd, F_SETLKW, &fl) != -1;
  }

  void UnlockShared() {
    if (m_lockFd != -1) {
      struct flock fl = {};
      fl.l_type = F_UNLCK;
      fl.l_whence = SEEK_SET;
      fcntl(m_lockFd, F_SETLK, &fl);
    }
  }

  void EnsureSharedInitialized() {
    std::call_once(m_sharedOnce, [this]() {
      auto fallbackPath = []() {
        return FallbackMapPath();
      };

      auto openFallbackFile = [&]() {
        std::string path = fallbackPath();
        int fd = open(path.c_str(), O_CREAT | O_RDWR, 0666);
        if (fd == -1) {
          Core::Logger::Error("FakeIP: fallback open failed: " +
                              std::string(strerror(errno)));
        } else {
          Core::Logger::Warn("FakeIP: using fallback shared map file: " + path);
        }
        return fd;
      };

      // 初始化文件范围锁 (自动回收, 防死锁)
      m_lockFd = open(LockFilePath().c_str(), O_CREAT | O_RDWR, 0666);
      if (m_lockFd == -1) {
        Core::Logger::Error("FakeIP: open lock file failed: " +
                            std::string(strerror(errno)));
        return;
      }
      fchmod(m_lockFd, 0666); // 尝试设置为所有用户可读写

      LockShared();

      // 初始化共享内存
      bool usingShm = true;
      int fd = shm_open(kSharedMapName, O_CREAT | O_RDWR, 0666);
      if (fd == -1) {
        Core::Logger::Warn("FakeIP: shm_open failed, fallback to file: " +
                           std::string(strerror(errno)));
        fd = openFallbackFile();
        usingShm = false;
        if (fd == -1) {
          UnlockShared();
          return;
        }
      }

      // 仅在 size 不足时扩容，避免对已有对象重复 ftruncate 触发错误
      struct stat st;
      if (fstat(fd, &st) == -1) {
        Core::Logger::Error("FakeIP: fstat failed: " +
                            std::string(strerror(errno)));
        close(fd);
        UnlockShared();
        return;
      }

      if (st.st_size < (off_t)sizeof(SharedTable)) {
        if (ftruncate(fd, sizeof(SharedTable)) == -1) {
          if (usingShm) {
            Core::Logger::Warn("FakeIP: ftruncate on shm failed, fallback to "
                               "file: " +
                               std::string(strerror(errno)));
            close(fd);
            fd = openFallbackFile();
            usingShm = false;
            if (fd == -1) {
              UnlockShared();
              return;
            }
            if (ftruncate(fd, sizeof(SharedTable)) == -1) {
              Core::Logger::Error("FakeIP: fallback ftruncate failed: " +
                                  std::string(strerror(errno)));
              close(fd);
              UnlockShared();
              return;
            }
          } else {
            Core::Logger::Error("FakeIP: ftruncate failed: " +
                                std::string(strerror(errno)));
            close(fd);
            UnlockShared();
            return;
          }
        }
      } else if (st.st_size != (off_t)sizeof(SharedTable) && usingShm) {
        // shm 已存在且尺寸异常，切到 file-backed，避免 mmap size 风险
        Core::Logger::Warn("FakeIP: unexpected shm size, fallback to file");
        close(fd);
        fd = openFallbackFile();
        usingShm = false;
        if (fd == -1) {
          UnlockShared();
          return;
        }
        if (ftruncate(fd, sizeof(SharedTable)) == -1) {
          Core::Logger::Error("FakeIP: fallback ftruncate failed: " +
                              std::string(strerror(errno)));
          close(fd);
          UnlockShared();
          return;
        }
      }

      void *ptr = mmap(NULL, sizeof(SharedTable), PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
      if (ptr == MAP_FAILED) {
        Core::Logger::Error("FakeIP: mmap failed");
        close(fd);
        UnlockShared();
        return;
      }

      close(fd);

      m_shared = static_cast<SharedTable *>(ptr);

      // 检查是否需要初始化
      if (m_shared->magic != kSharedMagic ||
          m_shared->capacity != kSharedCapacity) {
        std::memset(m_shared, 0, sizeof(SharedTable));
        m_shared->magic = kSharedMagic;
        m_shared->capacity = kSharedCapacity;
        m_shared->cursor = 0;
        Core::Logger::Info("FakeIP: Shared memory initialized");
      }

      UnlockShared();
    });
  }

  void SharedPut(uint32_t ipHostOrder, const std::string &domain) {
    if (domain.empty())
      return;
    EnsureSharedInitialized();
    if (!m_shared)
      return;
    if (!LockShared())
      return;

    uint32_t idx = m_shared->cursor++ % kSharedCapacity;
    SharedEntry &entry = m_shared->entries[idx];
    entry.ip = ipHostOrder;
    entry.tick = GetTickCount64();

    size_t n = std::min(domain.size(), kSharedDomainMax);
    std::memcpy(entry.domain, domain.data(), n);
    entry.domain[n] = '\0';

    UnlockShared();
  }

  std::string SharedGet(uint32_t ipHostOrder) {
    EnsureSharedInitialized();
    if (!m_shared)
      return "";
    if (!LockShared())
      return "";

    const SharedEntry *best = nullptr;
    uint64_t bestTick = 0;

    for (uint32_t i = 0; i < kSharedCapacity; i++) {
      const SharedEntry &entry = m_shared->entries[i];
      if (entry.ip == ipHostOrder && entry.domain[0] != '\0') {
        if (entry.tick >= bestTick) {
          bestTick = entry.tick;
          best = &entry;
        }
      }
    }

    std::string result = best ? best->domain : "";
    UnlockShared();
    return result;
  }

  void EnsureInitialized() {
    std::call_once(m_initOnce, [this]() {
      std::lock_guard<std::mutex> lock(m_mtx);
      auto &config = Core::Config::Instance();
      std::string cidr = config.fakeIp.cidr;

      if (ParseCidr(cidr, m_baseIp, m_mask)) {
        m_networkSize = ~m_mask + 1;
        Core::Logger::Info("FakeIP: Initialized CIDR=" + cidr +
                           " Size=" + std::to_string(m_networkSize));
      } else {
        Core::Logger::Error("FakeIP: Failed parsing " + cidr +
                            ", fallback to 198.18.0.0/15");
        ParseCidr("198.18.0.0/15", m_baseIp, m_mask);
        m_networkSize = ~m_mask + 1;
      }
    });
  }

  bool ParseCidr(const std::string &cidr, uint32_t &outBase,
                 uint32_t &outMask) {
    size_t slash = cidr.find('/');
    if (slash == std::string::npos)
      return false;
    std::string ip = cidr.substr(0, slash);
    int bits = std::stoi(cidr.substr(slash + 1));

    struct in_addr addr;
    if (inet_pton(AF_INET, ip.c_str(), &addr) != 1)
      return false;

    outBase = ntohl(addr.s_addr);
    if (bits == 0)
      outMask = 0;
    else
      outMask = 0xFFFFFFFF << (32 - bits);
    outBase &= outMask;
    return true;
  }

public:
  FakeIP() : m_baseIp(0), m_mask(0), m_networkSize(0), m_cursor(1) {}

  static FakeIP &Instance() {
    static FakeIP instance;
    instance.EnsureInitialized();
    return instance;
  }

  bool IsFakeIP(uint32_t ipNetworkOrder) {
    EnsureInitialized();
    // 注意：为了性能这里不加锁，base/mask 初始化后是常量，应该是安全的
    uint32_t ip = ntohl(ipNetworkOrder);
    return (ip & m_mask) == m_baseIp;
  }

  uint32_t Alloc(const std::string &domain) {
    EnsureInitialized();
    std::lock_guard<std::mutex> lock(m_mtx);

    if (m_domainToIp.count(domain))
      return htonl(m_domainToIp[domain]);

    if (m_networkSize <= 2)
      return 0;

    uint32_t offset = m_cursor++;
    if (m_cursor >= m_networkSize - 1)
      m_cursor = 1;

    uint32_t newIp = m_baseIp | offset;

    // 清理旧映射
    if (m_ipToDomain.count(newIp)) {
      m_domainToIp.erase(m_ipToDomain[newIp]);
    }

    m_ipToDomain[newIp] = domain;
    m_domainToIp[domain] = newIp;

    SharedPut(newIp, domain);
    return htonl(newIp);
  }

  std::string GetDomain(uint32_t ipNetworkOrder) {
    EnsureInitialized();
    std::lock_guard<std::mutex> lock(m_mtx);

    uint32_t ip = ntohl(ipNetworkOrder);
    if (m_ipToDomain.count(ip))
      return m_ipToDomain[ip];

    // 尝试从共享内存获取
    std::string domain = SharedGet(ip);
    if (!domain.empty()) {
      m_ipToDomain[ip] = domain;
      m_domainToIp[domain] = ip;
      return domain;
    }
    return "";
  }
};
} // namespace Network
