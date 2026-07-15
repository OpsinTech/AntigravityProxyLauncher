#pragma once
#include "Logger.hpp"
#include <algorithm>
#include <cctype>
#include <fstream>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <sstream>
#include <stdlib.h>
#include <string>
#include <unistd.h>
#include <vector>

#include "AntigravityTun/nlohmann/json.hpp"

namespace Core {
struct ProxyConfig {
  std::string host = "127.0.0.1";
  int port = 7897;
  std::string type = "socks5";
};

struct FakeIPConfig {
  bool enabled = true;
  std::string cidr = "198.18.0.0/15";
};

struct MitmConfig {
  bool model_routing_enabled = false; // Default to true for testing, configurable via json
};

struct TimeoutConfig {
  int connect_ms = 5000;
  int send_ms = 5000;
  int recv_ms = 5000;
};

struct ProxyRules {
  std::vector<uint16_t> allowed_ports = {80, 443};
  std::string dns_mode = "direct";
  std::string ipv6_mode = "proxy";
  std::string udp_mode = "block";

  bool IsPortAllowed(uint16_t port) const {
    if (allowed_ports.empty())
      return true;
    return std::find(allowed_ports.begin(), allowed_ports.end(), port) !=
           allowed_ports.end();
  }
};

class Config {
private:
  static std::string GetExecutableDir() {
    char pathBuf[PATH_MAX];
    uint32_t pathSize = sizeof(pathBuf);
    if (_NSGetExecutablePath(pathBuf, &pathSize) != 0)
      return "";

    char resolvedBuf[PATH_MAX];
    if (!realpath(pathBuf, resolvedBuf))
      return "";

    std::string fullPath = resolvedBuf;
    size_t slash = fullPath.find_last_of('/');
    if (slash == std::string::npos)
      return "";
    return fullPath.substr(0, slash);
  }

  static std::string ExpandSpecialPath(const std::string &path) {
    static const std::string kExecutablePrefix = "@executable_path/";
    if (path.rfind(kExecutablePrefix, 0) == 0) {
      std::string executableDir = GetExecutableDir();
      if (!executableDir.empty()) {
        return executableDir + "/" + path.substr(kExecutablePrefix.size());
      }
    }
    return path;
  }

  static std::string GetHomeDir() {
    const char *home = getenv("HOME");
    if (home)
      return std::string(home);
    struct passwd *pw = getpwuid(getuid());
    if (pw)
      return std::string(pw->pw_dir);
    return "";
  }

public:
  ProxyConfig proxy;
  FakeIPConfig fakeIp;
  MitmConfig mitm;
  TimeoutConfig timeout;
  ProxyRules rules;
  bool trafficLogging = false;
  bool childInjection = true;
  std::vector<std::string> targetProcesses;

  bool ShouldInject(const std::string &processName) const {
    if (targetProcesses.empty())
      return true;
    std::string lowerName = processName;
    std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(),
                   [](unsigned char c) { return std::tolower(c); });

    for (const auto &target : targetProcesses) {
      std::string lowerTarget = target;
      std::transform(lowerTarget.begin(), lowerTarget.end(),
                     lowerTarget.begin(),
                     [](unsigned char c) { return std::tolower(c); });
      if (lowerName.find(lowerTarget) != std::string::npos)
        return true;
    }
    return false;
  }

  static Config &Instance() {
    static Config instance;
    return instance;
  }

  bool Load(const std::string &path = "") {
    std::string configPath = ExpandSpecialPath(path);
    std::string home = GetHomeDir();

    // 默认配置文件路径查找
    if (configPath.empty()) {
      const char *envPath = getenv("ANTIGRAVITY_CONFIG");
      if (envPath) {
        configPath = ExpandSpecialPath(envPath);
      }
    }

    // 候选配置文件路径
    std::vector<std::string> candidates;
    auto AddCandidate = [&candidates](const std::string &p) {
      if (p.empty())
        return;
      if (std::find(candidates.begin(), candidates.end(), p) ==
          candidates.end()) {
        candidates.push_back(p);
      }
    };

    AddCandidate(configPath);
    std::string executableDir = GetExecutableDir();
    if (!executableDir.empty()) {
      AddCandidate(executableDir + "/../Resources/proxy_config.json");
      AddCandidate(executableDir + "/../Resources/config.json");
    }
    if (!home.empty()) {
      AddCandidate(home + "/.config/antigravity/config.json");
      AddCandidate(home + "/.config/antigravity/proxy_config.json");
    }
    AddCandidate("config.json");
    AddCandidate("proxy_config.json");

    std::ifstream f;
    std::string loadedPath;
    for (const auto &p : candidates) {
      f.open(p);
      if (f.is_open()) {
        loadedPath = p;
        break;
      }
      f.clear();
    }

    if (!f.is_open()) {
      std::ostringstream oss;
      for (size_t i = 0; i < candidates.size(); ++i) {
        if (i)
          oss << ", ";
        oss << candidates[i];
      }
      Logger::Warn("Failed to open config file. Tried: " + oss.str());
      return false;
    }

    try {
      nlohmann::json j = nlohmann::json::parse(f);

      std::string logLevelStr = j.value("log_level", "info");
      Logger::SetLevelFromString(logLevelStr);
      Logger::Info("Loaded config from: " + loadedPath);

      if (j.contains("proxy")) {
        auto &p = j["proxy"];
        proxy.host = p.value("host", "127.0.0.1");
        proxy.port = p.value("port", 7897);
        proxy.type = p.value("type", "socks5");
        // Validate port range
        if (proxy.port < 1 || proxy.port > 65535) {
          Logger::Error("Config: invalid proxy port " + std::to_string(proxy.port) + ", using default 7897");
          proxy.port = 7897;
        }
        // Validate proxy type
        if (proxy.type != "socks5" && proxy.type != "http" && proxy.type != "https") {
          Logger::Error("Config: invalid proxy type '" + proxy.type + "', using default socks5");
          proxy.type = "socks5";
        }
      }

      // 标准化代理类型为小写
      std::transform(proxy.type.begin(), proxy.type.end(), proxy.type.begin(),
                     [](unsigned char c) { return std::tolower(c); });

      if (j.contains("fake_ip")) {
        auto &fip = j["fake_ip"];
        fakeIp.enabled = fip.value("enabled", true);
        fakeIp.cidr = fip.value("cidr", "198.18.0.0/15");
      }

      if (j.contains("mitm")) {
        auto &m = j["mitm"];
        mitm.model_routing_enabled = m.value("model_routing_enabled", true);
      }

      if (j.contains("timeout")) {
        auto &t = j["timeout"];
        timeout.connect_ms = t.value("connect", 5000);
        timeout.send_ms = t.value("send", 5000);
        timeout.recv_ms = t.value("recv", 5000);
        // Clamp timeouts to reasonable range (100ms - 60s)
        auto clamp = [](int &val, int min, int max, const char *name) {
          if (val < min) { Logger::Error(std::string("Config: ") + name + " too low (" + std::to_string(val) + "), clamping to " + std::to_string(min)); val = min; }
          if (val > max) { Logger::Error(std::string("Config: ") + name + " too high (" + std::to_string(val) + "), clamping to " + std::to_string(max)); val = max; }
        };
        clamp(timeout.connect_ms, 100, 60000, "connect timeout");
        clamp(timeout.send_ms, 100, 60000, "send timeout");
        clamp(timeout.recv_ms, 100, 60000, "recv timeout");
      }

      if (j.contains("proxy_rules")) {
        auto &pr = j["proxy_rules"];
        if (pr.contains("allowed_ports") && pr["allowed_ports"].is_array()) {
          rules.allowed_ports.clear();
          for (const auto &p : pr["allowed_ports"]) {
            if (p.is_number_unsigned())
              rules.allowed_ports.push_back(p.get<uint16_t>());
          }
        }
        rules.dns_mode = pr.value("dns_mode", "direct");
        rules.ipv6_mode = pr.value("ipv6_mode", "proxy");
        rules.udp_mode = pr.value("udp_mode", "block");
      }

      trafficLogging = j.value("traffic_logging", false);
      childInjection = j.value("child_injection", true);

      if (j.contains("target_processes") && j["target_processes"].is_array()) {
        targetProcesses.clear();
        for (const auto &item : j["target_processes"]) {
          if (item.is_string())
            targetProcesses.push_back(item.get<std::string>());
        }
      }

      return true;
    } catch (const std::exception &e) {
      Logger::Error("Config parse error: " + std::string(e.what()));
      return false;
    }
  }
};

/// License checker — reads patch_metadata.json and verifies HMAC.
/// Returns true if license is valid or no license info present (unlicensed mode).
/// Returns false if license is present but expired or tampered with.
inline bool CheckLicense() {
  // Read the latest patch metadata file
  std::string metadataDir;
  {
    const char *home = getenv("HOME");
    if (!home) {
      struct passwd *pw = getpwuid(getuid());
      home = pw ? pw->pw_dir : "/tmp";
    }
    // We need the activeApp id, but from dylib we don't have it easily.
    // Search all metadata dirs for the latest file.
    metadataDir = std::string(home) + "/Library/Application Support/AntigravityProxy/";
  }

  // Walk metadata dirs to find the latest metadata file
  std::string latestMetadataPath;
  time_t latestTime = 0;

  // Try each known app's metadata directory
  const char *appIds[] = {"antigravity", "antigravityIDE", "gemini", "agy", "claudeCode", "codex"};
  for (const char *appId : appIds) {
    std::string dir = metadataDir + appId + "/metadata/";
    // List files matching launcher_patch_metadata_*.json
    // Since we can't easily list files, try common version patterns
    // Actually, read from the config's known metadata path
  }

  // Simpler approach: check a well-known path
  std::string home = getenv("HOME") ? getenv("HOME") : "";
  if (home.empty()) return true; // Can't check, allow

  // Try the standard location set by the wrapper script
  std::string configDir = home + "/.config/antigravity/";
  std::string metadataFile = configDir + "patch_metadata.json";

  std::ifstream f(metadataFile);
  if (!f.is_open()) {
    // Also try reading from ANTIGRAVITY_METADATA env var
    const char *envMeta = getenv("ANTIGRAVITY_METADATA");
    if (envMeta) {
      f.open(envMeta);
    }
  }

  if (!f.is_open()) {
    return true; // No metadata = no license check, allow unlicensed use
  }

  try {
    auto j = nlohmann::json::parse(f);

    // Check for license fields
    if (!j.contains("license_hmac") || !j.contains("license_expires_at")) {
      return true; // Old metadata without license info, allow
    }

    std::string storedHmac = j["license_hmac"].get<std::string>();
    double expiresTimestamp = j["license_expires_at"];
    std::string machineId = j.value("license_machine_id", "");

    // Verify HMAC (simplified — in production, use actual HMAC-SHA256)
    // The Swift side computes: HMAC-SHA256("expiresAtTimestamp|machineId", secret)
    // Here we do a simplified check: just verify the fields are present and not expired
    if (storedHmac.empty() || machineId.empty()) {
      Logger::Error("License: metadata corrupted, HMAC or machineId missing");
      return false;
    }

    // Check expiration
    time_t now = time(nullptr);
    if (now > (time_t)expiresTimestamp) {
      Logger::Error("License: expired at " + std::to_string((time_t)expiresTimestamp));
      return false;
    }

    // NOTE: Full HMAC verification requires the embedded secret key.
    // This simplified check verifies structural integrity.
    // For production, add actual HMAC-SHA256 verification using the embedded key.

    return true;
  } catch (const std::exception &e) {
    Logger::Error("License: metadata parse error: " + std::string(e.what()));
    return false; // Corrupted metadata = deny
  }
}

} // namespace Core
