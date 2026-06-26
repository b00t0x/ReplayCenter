#include "third_party/tsreadex/aac.hpp"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <string>
#include <vector>

namespace {

constexpr int TS_PACKET_SIZE = 188;
constexpr int SYNC_BYTE = 0x47;
constexpr int PID_PAT = 0x0000;
constexpr int STREAM_TYPE_AAC_ADTS = 0x0f;

enum class AudioMode : int {
    Stereo = 0,
    Left = 1,
    Right = 2,
};

std::atomic<int> g_mode(static_cast<int>(AudioMode::Stereo));

AudioMode currentMode()
{
    return static_cast<AudioMode>(g_mode.load(std::memory_order_relaxed));
}

void setMode(AudioMode mode)
{
    g_mode.store(static_cast<int>(mode), std::memory_order_relaxed);
}

void handleSignal(int signal)
{
    switch (signal) {
    case SIGUSR1:
        setMode(AudioMode::Left);
        break;
    case SIGUSR2:
        setMode(AudioMode::Right);
        break;
    case SIGHUP:
        setMode(AudioMode::Stereo);
        break;
    default:
        break;
    }
}

bool parseMode(const std::string &value, AudioMode *mode)
{
    if (value == "stereo" || value == "s") {
        *mode = AudioMode::Stereo;
        return true;
    }
    if (value == "left" || value == "l") {
        *mode = AudioMode::Left;
        return true;
    }
    if (value == "right" || value == "r") {
        *mode = AudioMode::Right;
        return true;
    }
    return false;
}

bool parseBool(const std::string &value, bool *output)
{
    if (value == "true" || value == "yes" || value == "1" || value == "on") {
        *output = true;
        return true;
    }
    if (value == "false" || value == "no" || value == "0" || value == "off") {
        *output = false;
        return true;
    }
    return false;
}

int pidOf(const uint8_t *packet)
{
    return ((packet[1] & 0x1f) << 8) | packet[2];
}

bool payloadUnitStart(const uint8_t *packet)
{
    return (packet[1] & 0x40) != 0;
}

int continuityCounter(const uint8_t *packet)
{
    return packet[3] & 0x0f;
}

int payloadOffset(const uint8_t *packet)
{
    int adaptation = (packet[3] >> 4) & 0x03;
    if (adaptation == 0 || adaptation == 2) {
        return -1;
    }

    int offset = 4;
    if (adaptation == 3) {
        int adaptationLength = packet[offset];
        offset += 1 + adaptationLength;
        if (offset > TS_PACKET_SIZE) {
            return -1;
        }
    }
    return offset;
}

bool parsePat(const uint8_t *payload, int size, int *pmtPid)
{
    if (size <= 0) {
        return false;
    }

    int pointer = payload[0];
    if (pointer + 8 >= size) {
        return false;
    }

    const uint8_t *section = payload + 1 + pointer;
    int sectionSize = size - 1 - pointer;
    if (sectionSize < 8 || section[0] != 0x00) {
        return false;
    }

    int sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    if (sectionLength + 3 > sectionSize || sectionLength < 9) {
        return false;
    }

    int entriesEnd = 3 + sectionLength - 4;
    for (int offset = 8; offset + 4 <= entriesEnd; offset += 4) {
        int programNumber = (section[offset] << 8) | section[offset + 1];
        int pid = ((section[offset + 2] & 0x1f) << 8) | section[offset + 3];
        if (programNumber != 0) {
            *pmtPid = pid;
            return true;
        }
    }
    return false;
}

bool parsePmt(const uint8_t *payload, int size, int *audioPid)
{
    if (size <= 0) {
        return false;
    }

    int pointer = payload[0];
    if (pointer + 12 >= size) {
        return false;
    }

    const uint8_t *section = payload + 1 + pointer;
    int sectionSize = size - 1 - pointer;
    if (sectionSize < 12 || section[0] != 0x02) {
        return false;
    }

    int sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    if (sectionLength + 3 > sectionSize || sectionLength < 13) {
        return false;
    }

    int programInfoLength = ((section[10] & 0x0f) << 8) | section[11];
    int offset = 12 + programInfoLength;
    int entriesEnd = 3 + sectionLength - 4;
    while (offset + 5 <= entriesEnd) {
        int streamType = section[offset];
        int elementaryPid = ((section[offset + 1] & 0x1f) << 8) | section[offset + 2];
        int esInfoLength = ((section[offset + 3] & 0x0f) << 8) | section[offset + 4];
        if (streamType == STREAM_TYPE_AAC_ADTS) {
            *audioPid = elementaryPid;
            return true;
        }
        offset += 5 + esInfoLength;
    }
    return false;
}

void writeAll(FILE *out, const uint8_t *data, size_t size)
{
    while (size > 0) {
        size_t written = fwrite(data, 1, size, out);
        if (written == 0) {
            std::exit(2);
        }
        data += written;
        size -= written;
    }
}

void setPesPacketLength(std::vector<uint8_t> &pes)
{
    if (pes.size() < 6) {
        return;
    }

    size_t payloadLength = pes.size() - 6;
    if (payloadLength > 0xffff) {
        pes[4] = 0;
        pes[5] = 0;
    } else {
        pes[4] = static_cast<uint8_t>(payloadLength >> 8);
        pes[5] = static_cast<uint8_t>(payloadLength & 0xff);
    }
}

size_t pesPayloadOffset(const std::vector<uint8_t> &pes)
{
    if (pes.size() < 9) {
        return 0;
    }
    if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) {
        return 0;
    }
    size_t offset = 9 + pes[8];
    return offset < pes.size() ? offset : 0;
}

size_t pesDeclaredSize(const std::vector<uint8_t> &pes)
{
    if (pes.size() < 6) {
        return pes.size();
    }
    int pesPacketLength = (pes[4] << 8) | pes[5];
    if (pesPacketLength == 0) {
        return pes.size();
    }
    size_t declaredSize = 6 + static_cast<size_t>(pesPacketLength);
    return declaredSize <= pes.size() ? declaredSize : pes.size();
}

size_t countCompleteAdtsFrames(const uint8_t *payload, size_t size)
{
    size_t count = 0;
    size_t offset = 0;
    while (offset + 7 <= size) {
        if (!(payload[offset] == 0xff && (payload[offset + 1] & 0xf0) == 0xf0)) {
            ++offset;
            continue;
        }

        size_t pos = offset + 3;
        size_t frameLen = ((payload[pos] & 0x03) << 11) | (payload[pos + 1] << 3) | (payload[pos + 2] >> 5);
        if (frameLen < 7) {
            ++offset;
            continue;
        }
        if (offset + frameLen > size) {
            break;
        }

        ++count;
        offset += frameLen;
    }
    return count;
}

size_t countPesAdtsFrames(const std::vector<uint8_t> &pes)
{
    size_t offset = pesPayloadOffset(pes);
    if (offset == 0) {
        return 0;
    }
    size_t size = pesDeclaredSize(pes);
    if (offset >= size) {
        return 0;
    }
    return countCompleteAdtsFrames(pes.data() + offset, size - offset);
}

std::vector<uint8_t> transformPes(
    const std::vector<uint8_t> &pes,
    std::vector<uint8_t> &aacWorkspace,
    bool &isDualMono,
    AudioMode mode,
    bool muxSelectedToStereo,
    bool *converted
)
{
    *converted = false;
    if (mode == AudioMode::Stereo || pes.size() < 9) {
        return pes;
    }

    if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) {
        return pes;
    }

    int streamId = pes[3];
    if (streamId < 0xc0 || streamId > 0xdf) {
        return pes;
    }

    int pesPacketLength = (pes[4] << 8) | pes[5];
    size_t pesSize = pesPacketLength == 0 ? pes.size() : 6 + static_cast<size_t>(pesPacketLength);
    if (pesSize > pes.size()) {
        return pes;
    }

    int pesHeaderLength = pes[8];
    int aacOffset = 9 + pesHeaderLength;
    if (aacOffset >= static_cast<int>(pesSize)) {
        return pes;
    }

    std::vector<uint8_t> left;
    std::vector<uint8_t> right;
    Aac::TransmuxDualMono(
        left,
        right,
        aacWorkspace,
        isDualMono,
        muxSelectedToStereo,
        muxSelectedToStereo,
        pes.data() + aacOffset,
        pesSize - aacOffset
    );

    const std::vector<uint8_t> &selected = mode == AudioMode::Left ? left : right;
    if (!isDualMono || selected.empty()) {
        if (!isDualMono) {
            aacWorkspace.clear();
        }
        return pes;
    }

    std::vector<uint8_t> output;
    output.reserve(aacOffset + selected.size());
    output.insert(output.end(), pes.begin(), pes.begin() + aacOffset);
    output.insert(output.end(), selected.begin(), selected.end());
    setPesPacketLength(output);
    *converted = true;
    return output;
}

class TsWriter {
public:
    void setInitialCounter(int counter)
    {
        if (!initialized_) {
            counter_ = counter & 0x0f;
            initialized_ = true;
        }
    }

    void writePes(FILE *out, int pid, const std::vector<uint8_t> &pes)
    {
        size_t offset = 0;
        bool first = true;
        while (offset < pes.size()) {
            uint8_t packet[TS_PACKET_SIZE];
            std::memset(packet, 0xff, sizeof(packet));
            packet[0] = SYNC_BYTE;
            packet[1] = static_cast<uint8_t>(((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1f)));
            packet[2] = static_cast<uint8_t>(pid & 0xff);

            size_t remaining = pes.size() - offset;
            size_t payloadSize = remaining >= 184 ? 184 : remaining;
            int payloadStart = 4;

            if (payloadSize < 184) {
                int adaptationLength = static_cast<int>(183 - payloadSize);
                packet[3] = static_cast<uint8_t>(0x30 | (counter_ & 0x0f));
                packet[4] = static_cast<uint8_t>(adaptationLength);
                if (adaptationLength > 0) {
                    packet[5] = 0x00;
                }
                payloadStart = 5 + adaptationLength;
            } else {
                packet[3] = static_cast<uint8_t>(0x10 | (counter_ & 0x0f));
            }

            std::memcpy(packet + payloadStart, pes.data() + offset, payloadSize);
            writeAll(out, packet, sizeof(packet));
            counter_ = (counter_ + 1) & 0x0f;
            offset += payloadSize;
            first = false;
        }
        fflush(out);
    }

private:
    bool initialized_ = false;
    int counter_ = 0;
};

class Filter {
public:
    explicit Filter(int forcedAudioPid, bool muxSelectedToStereo)
        : audioPid_(forcedAudioPid)
        , muxSelectedToStereo_(muxSelectedToStereo)
        , lastMode_(currentMode())
    {
    }

    void processPacket(const uint8_t *packet, FILE *out)
    {
        int pid = pidOf(packet);
        int offset = payloadOffset(packet);

        if (pid == PID_PAT && offset >= 0) {
            int pmtPid = -1;
            if (parsePat(packet + offset, TS_PACKET_SIZE - offset, &pmtPid) && pmtPid_ != pmtPid) {
                pmtPid_ = pmtPid;
                std::fprintf(stderr, "[filter] pmt pid=0x%x\n", pmtPid_);
            }
        } else if (pid == pmtPid_ && offset >= 0 && audioPid_ < 0) {
            int audioPid = -1;
            if (parsePmt(packet + offset, TS_PACKET_SIZE - offset, &audioPid)) {
                audioPid_ = audioPid;
                std::fprintf(stderr, "[filter] audio pid=0x%x\n", audioPid_);
            }
        }

        if (pid == audioPid_) {
            audioWriter_.setInitialCounter(continuityCounter(packet));
            processAudioPacket(packet, offset, out);
            return;
        }

        writeAll(out, packet, TS_PACKET_SIZE);
    }

    void flush(FILE *out)
    {
        if (isCurrentPesComplete()) {
            flushPes(out);
        }
    }

private:
    void processAudioPacket(const uint8_t *packet, int offset, FILE *out)
    {
        if (payloadUnitStart(packet)) {
            if (isCurrentPesComplete()) {
                flushPes(out);
            }
            currentPes_.clear();
        }

        if (offset >= 0 && offset < TS_PACKET_SIZE) {
            currentPes_.insert(currentPes_.end(), packet + offset, packet + TS_PACKET_SIZE);
            if (isCurrentPesComplete()) {
                flushPes(out);
            }
        }
    }

    bool isCurrentPesComplete() const
    {
        if (currentPes_.size() < 6) {
            return false;
        }
        if (!(currentPes_[0] == 0x00 && currentPes_[1] == 0x00 && currentPes_[2] == 0x01)) {
            return false;
        }

        int pesPacketLength = (currentPes_[4] << 8) | currentPes_[5];
        return pesPacketLength != 0 && currentPes_.size() >= 6 + static_cast<size_t>(pesPacketLength);
    }

    void flushPes(FILE *out)
    {
        if (currentPes_.empty() || audioPid_ < 0) {
            return;
        }
        AudioMode mode = currentMode();
        resetAacStateIfModeChanged(mode);
        bool converted = false;
        std::vector<uint8_t> transformed = transformPes(
            currentPes_,
            aacWorkspace_,
            isDualMono_,
            mode,
            muxSelectedToStereo_,
            &converted
        );
        logTransform(converted, currentPes_, transformed, mode);
        audioWriter_.writePes(out, audioPid_, transformed);
        currentPes_.clear();
    }

    void resetAacStateIfModeChanged(AudioMode mode)
    {
        if (mode == lastMode_) {
            return;
        }
        aacWorkspace_.clear();
        isDualMono_ = false;
        lastMode_ = mode;
        std::fprintf(stderr, "[filter] audio mode state reset mode=%d\n", static_cast<int>(mode));
    }

    void logTransform(
        bool converted,
        const std::vector<uint8_t> &inputPes,
        const std::vector<uint8_t> &outputPes,
        AudioMode mode
    )
    {
        if (mode == AudioMode::Stereo) {
            return;
        }

        size_t inputFrames = countPesAdtsFrames(inputPes);
        size_t outputFrames = converted ? countPesAdtsFrames(outputPes) : inputFrames;

        if (converted) {
            ++convertedPesCount_;
            if (convertedPesCount_ <= 5 || convertedPesCount_ % 100 == 0) {
                std::fprintf(
                    stderr,
                    "[filter] converted pes mode=%d count=%zu bytes=%zu->%zu frames=%zu->%zu workspace=%zu\n",
                    static_cast<int>(mode),
                    convertedPesCount_,
                    inputPes.size(),
                    outputPes.size(),
                    inputFrames,
                    outputFrames,
                    aacWorkspace_.size()
                );
            }
        } else {
            ++passthroughPesCount_;
            if (passthroughPesCount_ <= 5 || passthroughPesCount_ % 100 == 0) {
                std::fprintf(
                    stderr,
                    "[filter] passthrough pes mode=%d count=%zu bytes=%zu frames=%zu workspace=%zu\n",
                    static_cast<int>(mode),
                    passthroughPesCount_,
                    inputPes.size(),
                    inputFrames,
                    aacWorkspace_.size()
                );
            }
        }
    }

    int pmtPid_ = -1;
    int audioPid_ = -1;
    bool muxSelectedToStereo_ = true;
    std::vector<uint8_t> currentPes_;
    std::vector<uint8_t> aacWorkspace_;
    TsWriter audioWriter_;
    bool isDualMono_ = false;
    AudioMode lastMode_;
    size_t convertedPesCount_ = 0;
    size_t passthroughPesCount_ = 0;
};

void usage(const char *program)
{
    std::fprintf(stderr, "Usage: %s [--mode stereo|left|right] [--audio-pid PID] [--mux-selected-to-stereo true|false]\n", program);
}

} // namespace

int main(int argc, char **argv)
{
    AudioMode mode = AudioMode::Stereo;
    int forcedAudioPid = -1;
    bool muxSelectedToStereo = true;

    for (int i = 1; i < argc; ++i) {
        std::string arg(argv[i]);
        if (arg == "--mode" && i + 1 < argc) {
            if (!parseMode(argv[++i], &mode)) {
                usage(argv[0]);
                return 1;
            }
        } else if (arg == "--audio-pid" && i + 1 < argc) {
            forcedAudioPid = static_cast<int>(std::strtol(argv[++i], nullptr, 0));
        } else if (arg == "--mux-selected-to-stereo" && i + 1 < argc) {
            if (!parseBool(argv[++i], &muxSelectedToStereo)) {
                usage(argv[0]);
                return 1;
            }
        } else if (arg == "--help" || arg == "-h") {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    setMode(mode);
    std::signal(SIGUSR1, handleSignal);
    std::signal(SIGUSR2, handleSignal);
    std::signal(SIGHUP, handleSignal);

    std::fprintf(
        stderr,
        "[filter] initial mode=%d forcedAudioPid=0x%x muxSelectedToStereo=%s\n",
        static_cast<int>(mode),
        forcedAudioPid,
        muxSelectedToStereo ? "true" : "false"
    );

    Filter filter(forcedAudioPid, muxSelectedToStereo);
    std::vector<uint8_t> buffer;
    buffer.reserve(TS_PACKET_SIZE * 16);

    uint8_t chunk[TS_PACKET_SIZE * 16];
    while (true) {
        size_t read = fread(chunk, 1, sizeof(chunk), stdin);
        if (read == 0) {
            break;
        }

        buffer.insert(buffer.end(), chunk, chunk + read);

        while (buffer.size() >= TS_PACKET_SIZE) {
            if (buffer[0] != SYNC_BYTE) {
                auto it = std::find(buffer.begin() + 1, buffer.end(), static_cast<uint8_t>(SYNC_BYTE));
                if (it == buffer.end()) {
                    buffer.clear();
                    break;
                }
                buffer.erase(buffer.begin(), it);
                if (buffer.size() < TS_PACKET_SIZE) {
                    break;
                }
            }

            filter.processPacket(buffer.data(), stdout);
            buffer.erase(buffer.begin(), buffer.begin() + TS_PACKET_SIZE);
        }
    }

    filter.flush(stdout);
    fflush(stdout);
    return 0;
}
