// Bounded, on-demand discovery only. No SDK calls or recurring network work.
#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <set>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

@interface UCSonyDiscoveryXML : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic, copy) NSString *serviceType;
@property(nonatomic, copy) NSString *servicePath;
@property(nonatomic) NSUInteger depth;
@property(nonatomic) NSUInteger nodes;
@end

@implementation UCSonyDiscoveryXML
- (instancetype)init {
  if ((self = [super init])) { _values = [NSMutableDictionary new]; _text = [NSMutableString new]; }
  return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attributes {
  (void)element; (void)uri; (void)qualified; (void)attributes;
  if (++_depth > 32 || ++_nodes > 2048) { [parser abortParsing]; return; }
  _text = [NSMutableString new];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
  if (_text.length + string.length > 1024) { [parser abortParsing]; return; }
  [_text appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
  (void)parser; (void)uri; (void)qualified;
  NSString *key = element.lowercaseString;
  NSString *value = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  static NSSet<NSString *> *keys;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ keys = [NSSet setWithArray:@[@"friendlyname", @"manufacturer", @"x_modelname", @"x_macaddress",
    @"x_ssh_support", @"x_ptp_remotecontrolsupport"]]; });
  if ([keys containsObject:key] && value.length && !_values[key]) _values[key] = value;
  if ([key isEqualToString:@"servicetype"]) _serviceType = value;
  if ([key isEqualToString:@"scpdurl"]) _servicePath = value;
  if ([key isEqualToString:@"service"]) {
    if ([_serviceType hasPrefix:@"urn:schemas-sony-com:service:DigitalImaging:"] && _servicePath.length)
      _values[@"digitalimagingpath"] = _servicePath;
    _serviceType = nil; _servicePath = nil;
  }
  if (_depth) --_depth;
  _text = [NSMutableString new];
}
- (NSData *)parser:(NSXMLParser *)parser resolveExternalEntityName:(NSString *)name systemID:(NSString *)systemID {
  (void)name; (void)systemID; [parser abortParsing]; return nil;
}
- (void)parser:(NSXMLParser *)parser foundInternalEntityDeclarationWithName:(NSString *)name value:(NSString *)value {
  (void)name; (void)value; [parser abortParsing];
}
- (void)parser:(NSXMLParser *)parser foundExternalEntityDeclarationWithName:(NSString *)name publicID:(NSString *)publicID systemID:(NSString *)systemID {
  (void)name; (void)publicID; (void)systemID; [parser abortParsing];
}
@end

namespace SonyNetwork {
using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;
static constexpr size_t maximumHeader = 16 * 1024;
static constexpr size_t maximumBody = 64 * 1024;
static constexpr size_t maximumDatagram = 16 * 1024;
static constexpr size_t maximumInterfaces = 16;
static constexpr size_t maximumCandidates = 16;
static constexpr auto scanDuration = std::chrono::milliseconds(2500);
static constexpr auto requestDuration = std::chrono::milliseconds(1500);
static constexpr auto descriptionDuration = std::chrono::seconds(4);

struct Socket {
  int value = -1;
  explicit Socket(int descriptor = -1) : value(descriptor) {}
  ~Socket() { if (value >= 0) close(value); }
  Socket(Socket &&other) noexcept : value(other.value) { other.value = -1; }
  Socket(const Socket &) = delete;
  Socket &operator=(const Socket &) = delete;
};
struct Interface { uint32_t address = 0, mask = 0; };
struct Candidate { uint32_t address = 0, localAddress = 0; std::string location; };
using Headers = std::map<std::string, std::string>;

static std::string lower(std::string value) {
  for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
  return value;
}
static std::string trim(std::string value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  return value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
static bool unicast(uint32_t address) {
  const uint32_t host = ntohl(address);
  return (host >> 24) != 0 && (host >> 24) != 127 && (host >> 24) < 224;
}
static bool onSubnet(uint32_t peer, const Interface &interface) {
  return unicast(peer) && peer != interface.address && interface.mask &&
    (peer & interface.mask) == (interface.address & interface.mask) &&
    (peer | interface.mask) != UINT32_MAX;
}
static NSString *addressString(uint32_t address) {
  struct in_addr value = {}; value.s_addr = address;
  char buffer[INET_ADDRSTRLEN] = {};
  return inet_ntop(AF_INET, &value, buffer, sizeof(buffer)) ? [NSString stringWithUTF8String:buffer] : @"";
}
static bool headerBlock(const std::string &bytes, Headers &headers) {
  if (bytes.empty() || bytes.size() > maximumHeader || bytes.find('\0') != std::string::npos) return false;
  auto end = bytes.find('\n');
  auto status = lower(trim(bytes.substr(0, end)));
  if (status.rfind("http/1.1 200", 0) != 0 && status.rfind("http/1.0 200", 0) != 0) return false;
  if (status.size() > 12 && status[12] != ' ') return false;
  if (end == std::string::npos) return false;
  size_t position = end + 1;
  while (position < bytes.size()) {
    end = bytes.find('\n', position);
    auto line = trim(bytes.substr(position, end == std::string::npos ? end : end - position));
    if (line.empty()) break;
    auto colon = line.find(':');
    if (colon == std::string::npos || colon == 0) return false;
    auto key = lower(trim(line.substr(0, colon)));
    auto value = trim(line.substr(colon + 1));
    if (key.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-_") != std::string::npos) return false;
    if (headers.count(key)) return false; // Avoid ambiguous LOCATION/length fields.
    headers.emplace(key, value);
    if (end == std::string::npos) break;
    position = end + 1;
  }
  return true;
}

static NSURLComponents *safeURL(NSString *url, uint32_t peer) {
  if (!url.length || url.length > 2048) return nil;
  if ([url rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  if (![parts.scheme.lowercaseString isEqualToString:@"http"] || parts.user || parts.password || parts.fragment || parts.query) return nil;
  struct in_addr host = {};
  if (!parts.host || inet_pton(AF_INET, parts.host.UTF8String, &host) != 1 || host.s_addr != peer || !unicast(peer)) return nil;
  if (parts.port && (parts.port.longLongValue < 1 || parts.port.longLongValue > 65535)) return nil;
  NSString *path = parts.percentEncodedPath;
  if (!path.length || ![path hasPrefix:@"/"] || path.length > 1024 || [path containsString:@"\r"] || [path containsString:@"\n"]) return nil;
  return parts;
}
static bool parseReply(const std::string &bytes, uint32_t peer, const Interface &interface, Candidate &result) {
  if (bytes.size() > maximumDatagram || !onSubnet(peer, interface)) return false;
  Headers headers;
  if (!headerBlock(bytes, headers) || !headers.count("location")) return false;
  auto signature = lower(bytes);
  if (signature.find("sonyimagingdevice") == std::string::npos || signature.find("sony corporation") == std::string::npos) return false;
  NSString *location = [[NSString alloc] initWithBytes:headers["location"].data() length:headers["location"].size() encoding:NSUTF8StringEncoding];
  if (!safeURL(location, peer)) return false;
  result = {peer, interface.address, headers["location"]};
  return true;
}

static int millisecondsLeft(Deadline deadline) {
  auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
  return left <= 0 ? 0 : (int)std::min<int64_t>(left, INT_MAX);
}
static bool waitSocket(int descriptor, short events, Deadline deadline) {
  for (;;) {
    int timeout = millisecondsLeft(deadline);
    if (!timeout) return false;
    pollfd item = {descriptor, events, 0};
    int result = poll(&item, 1, timeout);
    if (result < 0 && errno == EINTR) continue;
    return result > 0 && !(item.revents & (POLLERR | POLLNVAL)) && (item.revents & (events | POLLHUP));
  }
}

enum class BodyResult { incomplete, complete, invalid };
static BodyResult httpBody(const std::string &raw, bool eof, std::string &body) {
  auto marker = raw.find("\r\n\r\n");
  if (marker == std::string::npos) return raw.size() > maximumHeader || eof ? BodyResult::invalid : BodyResult::incomplete;
  if (marker + 4 > maximumHeader) return BodyResult::invalid;
  Headers headers;
  if (!headerBlock(raw.substr(0, marker + 4), headers)) return BodyResult::invalid;
  const std::string payload = raw.substr(marker + 4);
  if (payload.size() > maximumBody) return BodyResult::invalid;
  auto transfer = headers.find("transfer-encoding");
  auto length = headers.find("content-length");
  if (transfer != headers.end()) {
    if (lower(trim(transfer->second)) != "chunked" || length != headers.end()) return BodyResult::invalid;
    size_t position = 0;
    body.clear();
    while (position < payload.size()) {
      auto end = payload.find("\r\n", position);
      if (end == std::string::npos) return eof ? BodyResult::invalid : BodyResult::incomplete;
      std::string number = payload.substr(position, end - position);
      if (number.empty() || number.size() > 8 || number.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) return BodyResult::invalid;
      unsigned long size = strtoul(number.c_str(), nullptr, 16);
      if (size > maximumBody - body.size()) return BodyResult::invalid;
      position = end + 2;
      if (payload.size() - position < size + 2) return eof ? BodyResult::invalid : BodyResult::incomplete;
      if (payload.compare(position + size, 2, "\r\n") != 0) return BodyResult::invalid;
      if (!size) return BodyResult::complete;
      body.append(payload, position, size); position += size + 2;
    }
    return eof ? BodyResult::invalid : BodyResult::incomplete;
  }
  if (length != headers.end()) {
    if (length->second.empty() || length->second.size() > 8 || length->second.find_first_not_of("0123456789") != std::string::npos) return BodyResult::invalid;
    auto size = strtoul(length->second.c_str(), nullptr, 10);
    if (size > maximumBody || payload.size() > size) return BodyResult::invalid;
    if (payload.size() != size) return eof ? BodyResult::invalid : BodyResult::incomplete;
    body = payload; return BodyResult::complete;
  }
  if (!eof) return BodyResult::incomplete;
  body = payload; return BodyResult::complete;
}

static NSData *fetchXML(NSString *url, const Candidate &candidate, Deadline overallDeadline) {
  NSURLComponents *parts = safeURL(url, candidate.address);
  if (!parts) return nil;
  Deadline deadline = std::min(overallDeadline, Clock::now() + requestDuration);
  if (!millisecondsLeft(deadline)) return nil;
  Socket socket(::socket(AF_INET, SOCK_STREAM, 0));
  if (socket.value < 0 || fcntl(socket.value, F_SETFL, O_NONBLOCK) < 0) return nil;
  int yes = 1; setsockopt(socket.value, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
  sockaddr_in local = {}; local.sin_len = sizeof(local); local.sin_family = AF_INET; local.sin_addr.s_addr = candidate.localAddress;
  if (bind(socket.value, (sockaddr *)&local, sizeof(local)) < 0) return nil;
  sockaddr_in destination = {}; destination.sin_len = sizeof(destination); destination.sin_family = AF_INET;
  destination.sin_addr.s_addr = candidate.address; destination.sin_port = htons(parts.port ? parts.port.unsignedShortValue : 80);
  if (connect(socket.value, (sockaddr *)&destination, sizeof(destination)) < 0) {
    if (errno != EINPROGRESS || !waitSocket(socket.value, POLLOUT, deadline)) return nil;
    int error = 0; socklen_t size = sizeof(error);
    if (getsockopt(socket.value, SOL_SOCKET, SO_ERROR, &error, &size) < 0 || error) return nil;
  }
  NSString *requestString = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@:%u\r\nAccept: application/xml,text/xml\r\nConnection: close\r\n\r\n",
    parts.percentEncodedPath, addressString(candidate.address), (unsigned)ntohs(destination.sin_port)];
  std::string request = requestString.UTF8String;
  size_t sent = 0;
  while (sent < request.size()) {
    if (!waitSocket(socket.value, POLLOUT, deadline)) return nil;
    ssize_t count = send(socket.value, request.data() + sent, request.size() - sent, 0);
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (count <= 0) return nil;
    sent += (size_t)count;
  }
  std::string raw, body;
  std::array<char, 8192> buffer;
  for (;;) {
    if (!waitSocket(socket.value, POLLIN, deadline)) return nil;
    ssize_t count = recv(socket.value, buffer.data(), buffer.size(), 0);
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (count < 0) return nil;
    if (raw.size() + (size_t)count > maximumHeader + maximumBody) return nil;
    raw.append(buffer.data(), (size_t)count);
    auto result = httpBody(raw, count == 0, body);
    if (result == BodyResult::invalid) return nil;
    if (result == BodyResult::complete) return [NSData dataWithBytes:body.data() length:body.size()];
    if (count == 0) return nil;
  }
}

static NSDictionary<NSString *, NSString *> *parseXML(NSData *data) {
  if (!data.length || data.length > maximumBody) return nil;
  NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!xml || [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) return nil;
  UCSonyDiscoveryXML *delegate = [UCSonyDiscoveryXML new];
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
  parser.shouldProcessNamespaces = YES;
  parser.shouldResolveExternalEntities = NO;
  parser.delegate = delegate;
  return [parser parse] ? [delegate.values copy] : nil;
}

static std::vector<Interface> interfaces(NSString **error = nullptr) {
  std::vector<Interface> result;
  ifaddrs *list = nullptr;
  if (getifaddrs(&list) != 0) {
    int failure = errno;
    if (error) *error = [NSString stringWithFormat:@"Camera discovery cannot read local interfaces (getifaddrs: %s, errno %d).", strerror(failure), failure];
    return result;
  }
  std::set<uint32_t> addresses;
  size_t entries = 0, ipv4 = 0, eligible = 0;
  for (auto *item = list; item && result.size() < maximumInterfaces; item = item->ifa_next) {
    ++entries;
    if (item->ifa_addr && item->ifa_addr->sa_family == AF_INET) ++ipv4;
    const unsigned required = IFF_UP | IFF_RUNNING | IFF_MULTICAST;
    if (!item->ifa_addr || !item->ifa_netmask || item->ifa_addr->sa_family != AF_INET ||
        (item->ifa_flags & required) != required || (item->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT))) continue;
    ++eligible;
    uint32_t address = ((sockaddr_in *)item->ifa_addr)->sin_addr.s_addr;
    uint32_t mask = ((sockaddr_in *)item->ifa_netmask)->sin_addr.s_addr;
    if (!unicast(address) || !mask || !addresses.insert(address).second) continue;
    result.push_back({address, mask});
  }
  freeifaddrs(list);
  if (result.empty() && error) *error = [NSString stringWithFormat:@"Camera discovery found no usable local IPv4 interfaces (entries %zu, IPv4 %zu, eligible %zu). Check the network connection and Ultracam's local network permission.", entries, ipv4, eligible];
  return result;
}

static bool sendSearch(int descriptor) {
  sockaddr_in target = {}; target.sin_len = sizeof(target); target.sin_family = AF_INET; target.sin_port = htons(1900);
  inet_pton(AF_INET, "239.255.255.250", &target.sin_addr);
  static const char request[] = "M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\nMAN:\"ssdp:discover\"\r\nST:ssdp:all\r\nMX:1\r\n\r\n";
  return sendto(descriptor, request, sizeof(request) - 1, 0, (sockaddr *)&target, sizeof(target)) >= 0;
}

static std::vector<Candidate> scan(NSString **error) {
  NSString *interfaceError = nil;
  auto networkInterfaces = interfaces(&interfaceError);
  std::vector<Socket> sockets;
  std::vector<Interface> boundInterfaces;
  NSString *socketError = nil;
  auto failed = [&](const char *stage) {
    int failure = errno;
    if (!socketError) socketError = [NSString stringWithFormat:@"Camera discovery could not start (%s: %s, errno %d). Check Ultracam's local network permission.", stage, strerror(failure), failure];
  };
  for (const auto &interface : networkInterfaces) {
    Socket socket(::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP));
    if (socket.value < 0) { failed("socket"); continue; }
    if (fcntl(socket.value, F_SETFL, O_NONBLOCK) < 0) { failed("nonblocking socket"); continue; }
    sockaddr_in source = {}; source.sin_len = sizeof(source); source.sin_family = AF_INET; source.sin_addr.s_addr = interface.address;
    if (bind(socket.value, (sockaddr *)&source, sizeof(source)) < 0) { failed("bind"); continue; }
    if (setsockopt(socket.value, IPPROTO_IP, IP_MULTICAST_IF, &source.sin_addr, sizeof(source.sin_addr)) < 0) { failed("multicast interface"); continue; }
    if (!sendSearch(socket.value)) { failed("SSDP send"); continue; }
    sockets.push_back(std::move(socket)); boundInterfaces.push_back(interface);
  }
  std::vector<Candidate> result;
  if (sockets.empty()) {
    if (error) *error = socketError ?: interfaceError ?: @"No active local network interface is available for camera discovery. Check the network connection and Ultracam's local network permission.";
    return result;
  }
  std::vector<pollfd> polling;
  for (const auto &socket : sockets) polling.push_back({socket.value, POLLIN, 0});
  const Deadline deadline = Clock::now() + scanDuration;
  const Deadline retransmitAt = Clock::now() + std::chrono::milliseconds(800);
  bool retransmitted = false;
  std::set<uint32_t> seen;
  size_t received = 0;
  std::array<char, maximumDatagram + 1> buffer;
  while (millisecondsLeft(deadline) && received < 512 && result.size() < maximumCandidates) {
    if (!retransmitted && Clock::now() >= retransmitAt) {
      for (const auto &socket : sockets) sendSearch(socket.value);
      retransmitted = true;
    }
    int timeout = millisecondsLeft(deadline);
    if (!retransmitted) timeout = std::min(timeout, std::max(1, millisecondsLeft(retransmitAt)));
    int count = poll(polling.data(), (nfds_t)polling.size(), timeout);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) break;
    if (count == 0) continue;
    for (size_t i = 0; i < polling.size() && received < 512 && result.size() < maximumCandidates; ++i) {
      if (!(polling[i].revents & POLLIN)) {
        if (polling[i].revents & (POLLERR | POLLNVAL | POLLHUP)) polling[i].fd = -1;
        continue;
      }
      sockaddr_in peer = {}; socklen_t peerSize = sizeof(peer);
      ssize_t size = recvfrom(polling[i].fd, buffer.data(), buffer.size(), 0, (sockaddr *)&peer, &peerSize);
      if (size <= 0) continue;
      ++received;
      if ((size_t)size > maximumDatagram || peer.sin_family != AF_INET || seen.count(peer.sin_addr.s_addr)) continue;
      Candidate candidate;
      if (!parseReply(std::string(buffer.data(), (size_t)size), peer.sin_addr.s_addr, boundInterfaces[i], candidate)) continue;
      seen.insert(candidate.address); result.push_back(candidate);
    }
  }
  return result;
}

static NSDictionary *describe(const Candidate &candidate, Deadline deadline) {
  NSString *url = [NSString stringWithUTF8String:candidate.location.c_str()];
  NSDictionary *root = parseXML(fetchXML(url, candidate, deadline));
  if (!root) return nil;
  NSString *manufacturer = root[@"manufacturer"];
  if (manufacturer.length && [manufacturer rangeOfString:@"Sony" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
  NSDictionary *detail = root;
  if (!root[@"x_modelname"] || !root[@"x_macaddress"] || !root[@"x_ssh_support"]) {
    NSString *path = root[@"digitalimagingpath"];
    if (!path.length) return nil;
    NSURL *detailURL = [NSURL URLWithString:path relativeToURL:[NSURL URLWithString:url]].absoluteURL;
    if (!safeURL(detailURL.absoluteString, candidate.address)) return nil;
    detail = parseXML(fetchXML(detailURL.absoluteString, candidate, deadline));
  }
  if (!detail[@"x_modelname"] || !detail[@"x_macaddress"]) return nil;
  NSString *auth = [detail[@"x_ssh_support"] lowercaseString];
  if (![auth isEqualToString:@"enable"] && ![auth isEqualToString:@"disable"]) return nil;
  NSString *remote = [detail[@"x_ptp_remotecontrolsupport"] lowercaseString];
  if (remote.length && ![remote isEqualToString:@"enable"]) return nil;
  return @{@"model": detail[@"x_modelname"], @"mac": detail[@"x_macaddress"],
    @"name": root[@"friendlyname"] ?: @"", @"address": addressString(candidate.address), @"authentication": @([auth isEqualToString:@"enable"])};
}

static NSArray<NSDictionary *> *discover(NSString **error) {
  const auto candidates = scan(error);
  struct Results { std::mutex mutex; std::vector<NSDictionary *> records; };
  auto results = std::make_shared<Results>();
  dispatch_group_t group = dispatch_group_create();
  const Deadline deadline = Clock::now() + descriptionDuration;
  for (const auto &candidate : candidates) {
    const Candidate ownedCandidate = candidate;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @autoreleasepool {
        NSDictionary *record = describe(ownedCandidate, deadline);
        if (record) { std::lock_guard<std::mutex> lock(results->mutex); results->records.push_back(record); }
      }
    });
  }
  dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(descriptionDuration).count()));
  NSMutableArray *records = [NSMutableArray array];
  { std::lock_guard<std::mutex> lock(results->mutex); for (NSDictionary *record : results->records) [records addObject:record]; }
  return records;
}
}
