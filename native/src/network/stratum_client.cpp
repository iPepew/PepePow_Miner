#include "pepepow/stratum/client.hpp"

#include <nlohmann/json.hpp>

#include <array>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <unordered_map>

#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_handle = SOCKET;
constexpr socket_handle invalid_socket = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_handle = int;
constexpr socket_handle invalid_socket = -1;
#endif

namespace pepepow::stratum {
namespace {

using json = nlohmann::json;

void close_socket(socket_handle socket) {
#ifdef _WIN32
    closesocket(socket);
#else
    close(socket);
#endif
}

std::vector<std::uint8_t> hex_to_bytes(const std::string& hex) {
    if ((hex.size() & 1U) != 0U) throw std::invalid_argument("odd-length hex string");
    std::vector<std::uint8_t> out(hex.size() / 2U);
    for (std::size_t i = 0; i < out.size(); ++i) {
        const auto byte = hex.substr(i * 2U, 2U);
        out[i] = static_cast<std::uint8_t>(std::stoul(byte, nullptr, 16));
    }
    return out;
}

std::string bytes_to_hex(const std::uint8_t* data, std::size_t size) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (std::size_t i = 0; i < size; ++i) stream << std::setw(2) << static_cast<unsigned>(data[i]);
    return stream.str();
}

constexpr std::array<std::uint32_t, 64> sha_k{
    0x428a2f98U,0x71374491U,0xb5c0fbcfU,0xe9b5dba5U,0x3956c25bU,0x59f111f1U,0x923f82a4U,0xab1c5ed5U,
    0xd807aa98U,0x12835b01U,0x243185beU,0x550c7dc3U,0x72be5d74U,0x80deb1feU,0x9bdc06a7U,0xc19bf174U,
    0xe49b69c1U,0xefbe4786U,0x0fc19dc6U,0x240ca1ccU,0x2de92c6fU,0x4a7484aaU,0x5cb0a9dcU,0x76f988daU,
    0x983e5152U,0xa831c66dU,0xb00327c8U,0xbf597fc7U,0xc6e00bf3U,0xd5a79147U,0x06ca6351U,0x14292967U,
    0x27b70a85U,0x2e1b2138U,0x4d2c6dfcU,0x53380d13U,0x650a7354U,0x766a0abbU,0x81c2c92eU,0x92722c85U,
    0xa2bfe8a1U,0xa81a664bU,0xc24b8b70U,0xc76c51a3U,0xd192e819U,0xd6990624U,0xf40e3585U,0x106aa070U,
    0x19a4c116U,0x1e376c08U,0x2748774cU,0x34b0bcb5U,0x391c0cb3U,0x4ed8aa4aU,0x5b9cca4fU,0x682e6ff3U,
    0x748f82eeU,0x78a5636fU,0x84c87814U,0x8cc70208U,0x90befffaU,0xa4506cebU,0xbef9a3f7U,0xc67178f2U};

std::uint32_t rotr(std::uint32_t x, unsigned n) { return (x >> n) | (x << (32U - n)); }

std::array<std::uint8_t, 32> sha256(const std::vector<std::uint8_t>& input) {
    std::vector<std::uint8_t> data = input;
    const std::uint64_t bit_length = static_cast<std::uint64_t>(data.size()) * 8U;
    data.push_back(0x80U);
    while ((data.size() % 64U) != 56U) data.push_back(0U);
    for (int shift = 56; shift >= 0; shift -= 8) data.push_back(static_cast<std::uint8_t>(bit_length >> shift));

    std::array<std::uint32_t, 8> h{0x6a09e667U,0xbb67ae85U,0x3c6ef372U,0xa54ff53aU,0x510e527fU,0x9b05688cU,0x1f83d9abU,0x5be0cd19U};
    for (std::size_t offset = 0; offset < data.size(); offset += 64U) {
        std::array<std::uint32_t, 64> w{};
        for (std::size_t i = 0; i < 16; ++i) {
            const auto p = offset + i * 4U;
            w[i] = (static_cast<std::uint32_t>(data[p]) << 24U) | (static_cast<std::uint32_t>(data[p+1]) << 16U) |
                   (static_cast<std::uint32_t>(data[p+2]) << 8U) | static_cast<std::uint32_t>(data[p+3]);
        }
        for (std::size_t i = 16; i < 64; ++i) {
            const auto s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >> 3U);
            const auto s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >> 10U);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        auto a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (std::size_t i=0;i<64;++i) {
            const auto s1=rotr(e,6)^rotr(e,11)^rotr(e,25);
            const auto ch=(e&f)^((~e)&g);
            const auto t1=hh+s1+ch+sha_k[i]+w[i];
            const auto s0=rotr(a,2)^rotr(a,13)^rotr(a,22);
            const auto maj=(a&b)^(a&c)^(b&c);
            const auto t2=s0+maj;
            hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
    }
    std::array<std::uint8_t,32> out{};
    for (std::size_t i=0;i<8;++i) for (std::size_t j=0;j<4;++j) out[i*4+j]=static_cast<std::uint8_t>(h[i]>>(24U-j*8U));
    return out;
}

std::array<std::uint8_t, 32> sha256d(const std::vector<std::uint8_t>& input) {
    const auto first = sha256(input);
    return sha256(std::vector<std::uint8_t>(first.begin(), first.end()));
}

std::uint32_t parse_hex_u32(const std::string& value) {
    if (value.size() != 8U) throw std::invalid_argument("expected 8 hex characters");
    return static_cast<std::uint32_t>(std::stoul(value, nullptr, 16));
}

Hash256 parse_prevhash_words(const std::string& value) {
    if (value.size() != 64U) throw std::invalid_argument("invalid prevhash length");
    Hash256 result{};
    for (std::size_t word=0;word<8;++word) {
        auto bytes=hex_to_bytes(value.substr(word*8U,8U));
        std::reverse(bytes.begin(),bytes.end());
        std::copy(bytes.begin(),bytes.end(),result.begin()+static_cast<std::ptrdiff_t>(word*4U));
    }
    return result;
}

socket_handle connect_tcp(const Endpoint& endpoint) {
#ifdef _WIN32
    static std::once_flag startup_flag;
    std::call_once(startup_flag, [] { WSADATA data{}; if (WSAStartup(MAKEWORD(2,2), &data) != 0) throw std::runtime_error("WSAStartup failed"); });
#endif
    addrinfo hints{}; hints.ai_family=AF_UNSPEC; hints.ai_socktype=SOCK_STREAM;
    addrinfo* addresses=nullptr;
    const auto service=std::to_string(endpoint.port);
    if (getaddrinfo(endpoint.host.c_str(),service.c_str(),&hints,&addresses)!=0) throw std::runtime_error("cannot resolve pool host");
    socket_handle socket=invalid_socket;
    for (auto* current=addresses;current!=nullptr;current=current->ai_next) {
        socket=::socket(current->ai_family,current->ai_socktype,current->ai_protocol);
        if (socket==invalid_socket) continue;
        if (::connect(socket,current->ai_addr,static_cast<int>(current->ai_addrlen))==0) break;
        close_socket(socket); socket=invalid_socket;
    }
    freeaddrinfo(addresses);
    if (socket==invalid_socket) throw std::runtime_error("pool connection failed");
    return socket;
}

} // namespace

class Client::Impl {
public:
    explicit Impl(Config config): config_(std::move(config)) {}
    ~Impl(){ stop(); }

    void log(const std::string& text) { if (log_handler_) log_handler_(text); else std::cout << text << '\n'; }

    void send_json(const json& value) {
        const auto line=value.dump()+"\n";
        std::lock_guard lock(send_mutex_);
        if (socket_==invalid_socket) throw std::runtime_error("not connected");
        std::size_t sent=0;
        while (sent<line.size()) {
#ifdef _WIN32
            const int count=::send(socket_,line.data()+sent,static_cast<int>(line.size()-sent),0);
#else
            const auto count=::send(socket_,line.data()+sent,line.size()-sent,MSG_NOSIGNAL);
#endif
            if (count<=0) throw std::runtime_error("pool send failed");
            sent+=static_cast<std::size_t>(count);
        }
    }

    void handshake() {
        send_json({{"id",1},{"method","mining.subscribe"},{"params",json::array({config_.agent})}});
        send_json({{"id",2},{"method","mining.authorize"},{"params",json::array({config_.username,config_.password})}});
    }

    void handle(const json& message) {
        if (message.contains("id") && message["id"].is_number_integer()) {
            const auto id=message["id"].get<int>();
            if (id==1 && message.value("error",json{})==nullptr && message["result"].is_array()) {
                const auto& result=message["result"];
                if (result.size()>=3U) { extranonce1_=result[1].get<std::string>(); extranonce2_size_=result[2].get<std::size_t>(); log("Stratum subscribed: extranonce1="+extranonce1_); }
            } else if (id==2) {
                if (message.value("result",false)) log("Stratum authorized: "+config_.username); else throw std::runtime_error("pool authorization rejected");
            } else {
                std::lock_guard lock(pending_mutex_);
                auto it=pending_submit_.find(id);
                if (it!=pending_submit_.end()) {
                    if (message.value("result",false)) { ++accepted_; log("Share accepted"); } else { ++rejected_; log("Share rejected: "+message.value("error",json{}).dump()); }
                    pending_submit_.erase(it);
                }
            }
        }
        const auto method=message.value("method",std::string{});
        if (method=="mining.set_difficulty") {
            difficulty_=message.at("params").at(0).get<double>();
            log("Difficulty set to "+std::to_string(difficulty_));
        } else if (method=="mining.notify") {
            const auto& p=message.at("params");
            if (p.size()<9U) throw std::runtime_error("short mining.notify");
            Job job;
            job.job_id=p[0].get<std::string>(); job.prevhash=p[1].get<std::string>(); job.coinb1=p[2].get<std::string>(); job.coinb2=p[3].get<std::string>();
            job.merkle_branch=p[4].get<std::vector<std::string>>(); job.version=p[5].get<std::string>(); job.nbits=p[6].get<std::string>(); job.ntime=p[7].get<std::string>();
            job.clean_jobs=p[8].is_boolean()?p[8].get<bool>():p[8].get<int>()!=0; job.extranonce1=extranonce1_; job.extranonce2_size=extranonce2_size_; job.difficulty=difficulty_;
            if (job_handler_) job_handler_(job);
            log("New job "+job.job_id+(job.clean_jobs?" (clean)":""));
        } else if (method=="mining.set_extranonce") {
            const auto& p=message.at("params"); extranonce1_=p.at(0).get<std::string>(); extranonce2_size_=p.at(1).get<std::size_t>();
        }
    }

    void run() {
        stop_=false;
        while (!stop_) {
            try {
                socket_=connect_tcp(config_.primary);
                log("Connected to "+config_.primary.host+":"+std::to_string(config_.primary.port));
                handshake();
                std::string buffer; std::array<char,8192> chunk{};
                while (!stop_) {
#ifdef _WIN32
                    const int count=recv(socket_,chunk.data(),static_cast<int>(chunk.size()),0);
#else
                    const auto count=recv(socket_,chunk.data(),chunk.size(),0);
#endif
                    if (count<=0) throw std::runtime_error("pool disconnected");
                    buffer.append(chunk.data(),static_cast<std::size_t>(count));
                    std::size_t newline=0;
                    while ((newline=buffer.find('\n'))!=std::string::npos) {
                        auto line=buffer.substr(0,newline); buffer.erase(0,newline+1U);
                        if (!line.empty()) handle(json::parse(line));
                    }
                }
            } catch (const std::exception& error) {
                log(std::string("Stratum error: ")+error.what());
            }
            if (socket_!=invalid_socket) { close_socket(socket_); socket_=invalid_socket; }
            if (!stop_) { ++reconnects_; std::this_thread::sleep_for(std::chrono::seconds(config_.reconnect_seconds)); }
        }
    }

    void stop() {
        stop_=true;
        if (socket_!=invalid_socket) {
#ifdef _WIN32
            shutdown(socket_,SD_BOTH);
#else
            shutdown(socket_,SHUT_RDWR);
#endif
            close_socket(socket_); socket_=invalid_socket;
        }
    }

    bool submit(const Share& share) {
        try {
            const int id=next_id_++;
            { std::lock_guard lock(pending_mutex_); pending_submit_[id]=share.job_id; }
            send_json({{"id",id},{"method","mining.submit"},{"params",json::array({config_.username,share.job_id,share.extranonce2,share.ntime,share.nonce})}});
            return true;
        } catch (const std::exception& error) { log(std::string("Submit failed: ")+error.what()); return false; }
    }

    Config config_; JobHandler job_handler_; LogHandler log_handler_; std::atomic_bool stop_{false}; socket_handle socket_{invalid_socket};
    std::mutex send_mutex_; std::mutex pending_mutex_; std::unordered_map<int,std::string> pending_submit_; std::atomic_int next_id_{10};
    std::string extranonce1_; std::size_t extranonce2_size_{4}; double difficulty_{1.0};
    std::atomic_uint64_t accepted_{0},rejected_{0},reconnects_{0};
};

Client::Client(Config config):impl_(std::make_unique<Impl>(std::move(config))){}
Client::~Client()=default;
void Client::set_job_handler(JobHandler handler){impl_->job_handler_=std::move(handler);}
void Client::set_log_handler(LogHandler handler){impl_->log_handler_=std::move(handler);}
void Client::run(){impl_->run();}
void Client::stop(){impl_->stop();}
bool Client::submit(const Share& share){return impl_->submit(share);}
Stats Client::stats() const noexcept{return {impl_->accepted_.load(),impl_->rejected_.load(),impl_->reconnects_.load()};}

Endpoint parse_endpoint(const std::string& url) {
    Endpoint endpoint; std::string value=url;
    constexpr auto tcp="stratum+tcp://"; constexpr auto ssl="stratum+ssl://"; constexpr auto tcps="stratum+tcps://";
    if (value.rfind(tcp,0)==0) value.erase(0,std::strlen(tcp));
    else if (value.rfind(ssl,0)==0) { endpoint.tls=true; value.erase(0,std::strlen(ssl)); }
    else if (value.rfind(tcps,0)==0) { endpoint.tls=true; value.erase(0,std::strlen(tcps)); }
    const auto colon=value.rfind(':'); if (colon==std::string::npos) throw std::invalid_argument("pool URL must include port");
    endpoint.host=value.substr(0,colon); endpoint.port=static_cast<std::uint16_t>(std::stoul(value.substr(colon+1U)));
    if (endpoint.host.empty()||endpoint.port==0U) throw std::invalid_argument("invalid pool URL");
    if (endpoint.tls) throw std::invalid_argument("TLS endpoint support is not enabled in this build");
    return endpoint;
}

MiningJob build_mining_job(const Job& job,const std::string& extranonce2) {
    auto coinbase=hex_to_bytes(job.coinb1+job.extranonce1+extranonce2+job.coinb2);
    auto merkle=sha256d(coinbase);
    for (const auto& branch_hex:job.merkle_branch) {
        auto branch=hex_to_bytes(branch_hex); std::vector<std::uint8_t> joined; joined.reserve(64); joined.insert(joined.end(),merkle.begin(),merkle.end()); joined.insert(joined.end(),branch.begin(),branch.end()); merkle=sha256d(joined);
    }
    MiningJob result; result.job_id=job.job_id; result.version=parse_hex_u32(job.version); result.previous_hash=parse_prevhash_words(job.prevhash);
    std::copy(merkle.begin(),merkle.end(),result.merkle_root.begin()); result.ntime=parse_hex_u32(job.ntime); result.bits=parse_hex_u32(job.nbits); return result;
}

std::string encode_u32_le_hex(std::uint32_t value) {
    const std::array<std::uint8_t,4> bytes{static_cast<std::uint8_t>(value),static_cast<std::uint8_t>(value>>8U),static_cast<std::uint8_t>(value>>16U),static_cast<std::uint8_t>(value>>24U)};
    return bytes_to_hex(bytes.data(),bytes.size());
}

} // namespace pepepow::stratum
