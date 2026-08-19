#!/usr/bin/env python3
from pathlib import Path

src_path = Path("native/src/cuda/header80_backend_cuda118_v2.cu")
text = src_path.read_text()

replacements = []

old = r'''// Compute an 80-byte BLAKE3 hash when the first 64-byte chunk CV is already
// known. Header bytes 64..75 are job-constant; only bytes 76..79 (nonce) vary.
__device__ void blake80_tail(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t out[32]){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=d_first_cv[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    b[0]=le32(base+64);
    b[1]=le32(base+68);
    b[2]=le32(base+72);
    // The reference writes nonce big-endian into header[76..79], then BLAKE3
    // loads that word little-endian. Preserve that exact wire representation.
    b[3]=bswap32(nonce);
    compress(cv,b,16,kChunkEnd|kRoot,c);
    #pragma unroll
    for(int i=0;i<8;++i)put_le32(out+4*i,c[i]);
}

__device__ void blake32(const std::uint8_t in[32],std::uint8_t out[32]){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=kIv[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    #pragma unroll
    for(int i=0;i<8;++i)b[i]=le32(in+4*i);
    compress(cv,b,32,kChunkStart|kChunkEnd|kRoot,c);
    #pragma unroll
    for(int i=0;i<8;++i)put_le32(out+4*i,c[i]);
}
'''
new = r'''// KV6-A word pipeline. The three 32-byte hash stages stay as named 32-bit
// words in the hot path. A struct is intentional: it prevents a dynamic array
// index elsewhere from forcing the whole value into CUDA local memory.
struct HashWords8 {
    std::uint32_t w0,w1,w2,w3,w4,w5,w6,w7;
};

__device__ __forceinline__ std::uint32_t word_at(const HashWords8& h,int i){
    switch(i){
        case 0:return h.w0; case 1:return h.w1; case 2:return h.w2; case 3:return h.w3;
        case 4:return h.w4; case 5:return h.w5; case 6:return h.w6; default:return h.w7;
    }
}
__device__ __forceinline__ void set_word(HashWords8& h,int i,std::uint32_t v){
    switch(i){
        case 0:h.w0=v;break; case 1:h.w1=v;break; case 2:h.w2=v;break; case 3:h.w3=v;break;
        case 4:h.w4=v;break; case 5:h.w5=v;break; case 6:h.w6=v;break; default:h.w7=v;break;
    }
}
__device__ __forceinline__ void put_words_bytes(std::uint8_t* out,const HashWords8& h){
    put_le32(out+0,h.w0); put_le32(out+4,h.w1); put_le32(out+8,h.w2); put_le32(out+12,h.w3);
    put_le32(out+16,h.w4); put_le32(out+20,h.w5); put_le32(out+24,h.w6); put_le32(out+28,h.w7);
}

// Compute the 80-byte BLAKE3 tail directly to words. Header bytes 64..75 are
// job-constant; only bytes 76..79 (nonce) vary.
__device__ __forceinline__ void blake80_tail_words(
    const std::uint8_t* base,std::uint32_t nonce,HashWords8& out){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=d_first_cv[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    b[0]=le32(base+64);
    b[1]=le32(base+68);
    b[2]=le32(base+72);
    b[3]=bswap32(nonce);
    compress(cv,b,16,kChunkEnd|kRoot,c);
    out=HashWords8{c[0],c[1],c[2],c[3],c[4],c[5],c[6],c[7]};
}

__device__ __forceinline__ void blake32_words(const HashWords8& in,HashWords8& out){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=kIv[i];
    b[0]=in.w0; b[1]=in.w1; b[2]=in.w2; b[3]=in.w3;
    b[4]=in.w4; b[5]=in.w5; b[6]=in.w6; b[7]=in.w7;
    #pragma unroll
    for(int i=8;i<16;++i)b[i]=0U;
    compress(cv,b,32,kChunkStart|kChunkEnd|kRoot,c);
    out=HashWords8{c[0],c[1],c[2],c[3],c[4],c[5],c[6],c[7]};
}
'''
replacements.append((old, new, "word BLAKE3"))

old = r'''__device__ __forceinline__ std::uint8_t nibble(const std::uint8_t first[32],int j){
    const std::uint8_t x=first[j>>1];
    return (j&1) ? static_cast<std::uint8_t>(x&0x0fU) : static_cast<std::uint8_t>(x>>4U);
}
__device__ __forceinline__ void accumulate_row(
    int row,const std::uint8_t first[32],double hm,double nm,double& sw,double& product){
    #pragma unroll 1
    for(int j=0;j<64;++j){
        const double v=static_cast<double>(nibble(first,j));
        if(sw<=0.02){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=safe_complex(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw=product/1024.0-floor(product/1024.0);
    }
}

// Strict streamed mixer: the reference's sw dependency is preserved across all
// 64 rows, but product[64] and vec[64] are eliminated. Only the two products
// needed to emit the current output byte remain live.
__device__ void mix_streamed(const std::uint8_t first[32],std::uint8_t out[32],std::uint32_t nonce_wire){
    std::uint32_t hash_mod=0U;
    #pragma unroll
    for(int i=0;i<8;++i)hash_mod^=be32(first+4*i);
    const double hm=static_cast<double>(hash_mod);
    const double nm=static_cast<double>(nonce_wire&0xffU);
    double sw=0.0;

    #pragma unroll 1
    for(int pair=0;pair<32;++pair){
        double p0=0.0;
        double p1=0.0;
        accumulate_row(pair*2,first,hm,nm,sw,p0);
        accumulate_row(pair*2+1,first,hm,nm,sw,p1);
        const std::uint64_t p=static_cast<std::uint64_t>(p0)+static_cast<std::uint64_t>(p1);
        out[pair]=first[pair]^static_cast<std::uint8_t>(p&0xffU);
    }
}

template<bool Capture>
__device__ void hash_one(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* final,std::uint8_t* cap1,std::uint8_t* cap2){
    std::uint8_t first[32],mixed[32];
    blake80_tail(base,nonce,first);
    mix_streamed(first,mixed,bswap32(nonce));
    blake32(mixed,final);
    if(Capture){
        #pragma unroll
        for(int i=0;i<32;++i){cap1[i]=first[i];cap2[i]=mixed[i];}
    }
}

__device__ __forceinline__ bool hash_meets_target_be_device(const std::uint8_t hash[32]){
    #pragma unroll
    for(int i=0;i<32;++i){
        if(hash[i]<d_target[i])return true;
        if(hash[i]>d_target[i])return false;
    }
    return true;
}

__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    std::uint8_t hash[32];
    hash_one<false>(base,nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be_device(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){
        result->nonce=nonce;
        #pragma unroll
        for(int i=0;i<32;++i)result->hash[i]=hash[i];
    }
}
__global__ void diag_kernel(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* first,std::uint8_t* mixed,std::uint8_t* final){
    if(blockIdx.x||threadIdx.x)return;
    hash_one<true>(base,nonce,final,first,mixed);
}
'''
new = r'''__device__ __forceinline__ void accumulate_row_words(
    int row,const HashWords8& first,double hm,double nm,double& sw,double& product){
    // Full j unroll is safe here: this function appears twice in the pair-loop
    // body, while the pair loop itself remains explicitly NOT unrolled. Thus
    // word selection becomes compile-time without exploding 64 row copies.
    #pragma unroll
    for(int j=0;j<64;++j){
        const int wi=j>>3;
        const int ni=j&7;
        const std::uint32_t word=word_at(first,wi);
        const unsigned shift=static_cast<unsigned>((ni>>1)*8+((ni&1)?0:4));
        const double v=static_cast<double>((word>>shift)&0x0fU);
        if(sw<=0.02){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=safe_complex(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw=product/1024.0-floor(product/1024.0);
    }
}

__device__ __forceinline__ void mix_streamed_words(
    const HashWords8& first,HashWords8& out,std::uint32_t nonce_wire){
    const std::uint32_t hash_mod=
        bswap32(first.w0)^bswap32(first.w1)^bswap32(first.w2)^bswap32(first.w3)^
        bswap32(first.w4)^bswap32(first.w5)^bswap32(first.w6)^bswap32(first.w7);
    const double hm=static_cast<double>(hash_mod);
    const double nm=static_cast<double>(nonce_wire&0xffU);
    double sw=0.0;

    // Preserve exact pair/row order. Keeping both loops rolled avoids a giant
    // SASS body; the expensive 64-column row body is only present twice.
    #pragma unroll 1
    for(int wi=0;wi<8;++wi){
        const std::uint32_t first_word=word_at(first,wi);
        std::uint32_t packed=0U;
        #pragma unroll 1
        for(int lane=0;lane<4;++lane){
            const int pair=wi*4+lane;
            double p0=0.0;
            double p1=0.0;
            accumulate_row_words(pair*2,first,hm,nm,sw,p0);
            accumulate_row_words(pair*2+1,first,hm,nm,sw,p1);
            const std::uint64_t p=static_cast<std::uint64_t>(p0)+static_cast<std::uint64_t>(p1);
            const std::uint8_t src=static_cast<std::uint8_t>((first_word>>(lane*8))&0xffU);
            const std::uint8_t mixed=src^static_cast<std::uint8_t>(p&0xffU);
            packed|=static_cast<std::uint32_t>(mixed)<<(lane*8);
        }
        set_word(out,wi,packed);
    }
}

template<bool Capture>
__device__ __forceinline__ void hash_one_words(
    const std::uint8_t* base,std::uint32_t nonce,HashWords8& final,
    std::uint8_t* cap1,std::uint8_t* cap2){
    HashWords8 first{},mixed{};
    blake80_tail_words(base,nonce,first);
    mix_streamed_words(first,mixed,bswap32(nonce));
    blake32_words(mixed,final);
    if(Capture){
        put_words_bytes(cap1,first);
        put_words_bytes(cap2,mixed);
    }
}

__device__ __forceinline__ bool hash_meets_target_be_words(const HashWords8& hash){
    // Four-byte groups preserve the original bytewise big-endian lexicographic
    // order exactly. The loop is fixed and unrolled to keep hash words scalar.
    #pragma unroll
    for(int i=0;i<8;++i){
        const std::uint32_t h=bswap32(word_at(hash,i));
        const std::uint32_t t=be32(d_target+4*i);
        if(h<t)return true;
        if(h>t)return false;
    }
    return true;
}

__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    HashWords8 hash{};
    hash_one_words<false>(base,nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be_words(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){
        result->nonce=nonce;
        put_words_bytes(result->hash,hash);
    }
}
__global__ void diag_kernel(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* first,std::uint8_t* mixed,std::uint8_t* final){
    if(blockIdx.x||threadIdx.x)return;
    HashWords8 hash{};
    hash_one_words<true>(base,nonce,hash,first,mixed);
    put_words_bytes(final,hash);
}
'''
replacements.append((old, new, "word mixer/search"))

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"KV6-A transform failed: {label} marker count={count}, expected 1")
    text = text.replace(old, new)

required = [
    "struct HashWords8",
    "blake80_tail_words",
    "blake32_words",
    "accumulate_row_words",
    "mix_streamed_words",
    "hash_one_words",
    "hash_meets_target_be_words",
    "#pragma unroll 1\n    for(int wi=0;wi<8;++wi)",
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"KV6-A transform failed: missing {marker}")

for rejected in [
    "std::uint8_t first[32],mixed[32]",
    "hash_one<false>(base,nonce,hash,nullptr,nullptr)",
    "hash_meets_target_be_device(hash)",
    "__device__ void blake32(const std::uint8_t in[32]",
]:
    if rejected in text:
        raise SystemExit(f"KV6-A transform failed: legacy hot-path marker survived: {rejected}")

src_path.write_text(text)
print("[KV6-A] scalar word-register pipeline transform PASS")
print("[KV6-A] first/mixed/final representation: HashWords8 named uint32 words")
print("[KV6-A] pair loop: rolled; column loop: compile-time unrolled")
print("[KV6-A] byte materialization: diagnostics/share-hit only")
