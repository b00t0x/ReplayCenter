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

#ifdef REPLAYCENTER_RELEASE_BUILD
#define REPLAYCENTER_FILTER_DEBUG_LOG(...) do { } while (0)
#else
#define REPLAYCENTER_FILTER_DEBUG_LOG(...) std::fprintf(stderr, __VA_ARGS__)
#endif

constexpr int TS_PACKET_SIZE = 188;
constexpr int SYNC_BYTE = 0x47;
constexpr int PID_PAT = 0x0000;
constexpr int PID_EIT = 0x0012;
constexpr int PID_TIME = 0x0014;
constexpr int TABLE_ID_EIT_PRESENT_FOLLOWING_ACTUAL = 0x4e;
constexpr int TABLE_ID_TDT = 0x70;
constexpr int TABLE_ID_TOT = 0x73;
constexpr int DESCRIPTOR_TAG_EVENT_GROUP = 0xd6;
constexpr int STREAM_TYPE_AAC_ADTS = 0x0f;
constexpr int EVENT_RELAY_CLEAR_MISS_THRESHOLD = 4;

void writeAll(FILE *out, const uint8_t *data, size_t size);

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

struct PatProgramInfo {
    int programNumber = -1;
    int pmtPid = -1;
};

struct EventRelayCandidate {
    int groupType = -1;
    int sourceNetworkId = -1;
    int sourceTransportStreamId = -1;
    int sourceServiceId = -1;
    int sourceEventId = -1;
    int targetNetworkId = -1;
    int targetTransportStreamId = -1;
    int targetServiceId = -1;
    int targetEventId = -1;
};

bool parsePat(const uint8_t *payload, int size, PatProgramInfo *info)
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
            info->programNumber = programNumber;
            info->pmtPid = pid;
            return true;
        }
    }
    return false;
}

bool appendPsiSection(
    const uint8_t *packet,
    int offset,
    std::vector<uint8_t> *section,
    size_t *expectedSize
)
{
    if (offset < 0 || offset >= TS_PACKET_SIZE) {
        return false;
    }

    const uint8_t *payload = packet + offset;
    size_t payloadSize = TS_PACKET_SIZE - static_cast<size_t>(offset);

    if (payloadUnitStart(packet)) {
        if (payloadSize == 0) {
            return false;
        }

        int pointer = payload[0];
        if (1 + pointer >= static_cast<int>(payloadSize)) {
            section->clear();
            *expectedSize = 0;
            return false;
        }

        payload += 1 + pointer;
        payloadSize -= 1 + pointer;
        section->clear();
        *expectedSize = 0;
    } else if (section->empty()) {
        return false;
    }

    section->insert(section->end(), payload, payload + payloadSize);

    if (*expectedSize == 0 && section->size() >= 3) {
        int sectionLength = (((*section)[1] & 0x0f) << 8) | (*section)[2];
        if (sectionLength < 4 || sectionLength > 1021) {
            section->clear();
            return false;
        }
        *expectedSize = 3 + static_cast<size_t>(sectionLength);
    }

    return *expectedSize > 0 && section->size() >= *expectedSize;
}

bool parsePmtSection(const uint8_t *section, int sectionSize, std::vector<int> *audioPids)
{
    audioPids->clear();
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
            audioPids->push_back(elementaryPid);
        }
        offset += 5 + esInfoLength;
    }
    return !audioPids->empty();
}

bool parseEventGroupDescriptor(
    const uint8_t *body,
    int length,
    const EventRelayCandidate &source,
    EventRelayCandidate *candidate
)
{
    if (length < 1) {
        return false;
    }

    int groupType = body[0] >> 4;
    int eventCount = body[0] & 0x0f;
    if (groupType != 0x02 && groupType != 0x04) {
        return false;
    }

    if (groupType != 0x04 && groupType != 0x05) {
        int offset = 1;
        if (offset + eventCount * 4 > length || eventCount <= 0) {
            return false;
        }
        candidate->groupType = groupType;
        candidate->sourceNetworkId = source.sourceNetworkId;
        candidate->sourceTransportStreamId = source.sourceTransportStreamId;
        candidate->sourceServiceId = source.sourceServiceId;
        candidate->sourceEventId = source.sourceEventId;
        candidate->targetNetworkId = source.sourceNetworkId;
        candidate->targetTransportStreamId = source.sourceTransportStreamId;
        candidate->targetServiceId = (body[offset] << 8) | body[offset + 1];
        candidate->targetEventId = (body[offset + 2] << 8) | body[offset + 3];
        return true;
    }

    if (eventCount != 0 || length < 9) {
        return false;
    }

    int offset = 1;
    candidate->groupType = groupType;
    candidate->sourceNetworkId = source.sourceNetworkId;
    candidate->sourceTransportStreamId = source.sourceTransportStreamId;
    candidate->sourceServiceId = source.sourceServiceId;
    candidate->sourceEventId = source.sourceEventId;
    candidate->targetNetworkId = (body[offset] << 8) | body[offset + 1];
    candidate->targetTransportStreamId = (body[offset + 2] << 8) | body[offset + 3];
    candidate->targetServiceId = (body[offset + 4] << 8) | body[offset + 5];
    candidate->targetEventId = (body[offset + 6] << 8) | body[offset + 7];
    return true;
}

bool parseEitSection(
    const uint8_t *section,
    int sectionSize,
    int selectedServiceId,
    EventRelayCandidate *candidate
)
{
    if (selectedServiceId < 0
        || sectionSize < 18
        || section[0] != TABLE_ID_EIT_PRESENT_FOLLOWING_ACTUAL) {
        return false;
    }

    int sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    if (sectionLength + 3 > sectionSize || sectionLength < 15) {
        return false;
    }

    int serviceId = (section[3] << 8) | section[4];
    if (serviceId != selectedServiceId) {
        return false;
    }

    int transportStreamId = (section[8] << 8) | section[9];
    int originalNetworkId = (section[10] << 8) | section[11];
    int eventsEnd = 3 + sectionLength - 4;
    int offset = 14;
    if (offset + 12 > eventsEnd) {
        return false;
    }

    EventRelayCandidate source;
    source.sourceNetworkId = originalNetworkId;
    source.sourceTransportStreamId = transportStreamId;
    source.sourceServiceId = serviceId;
    source.sourceEventId = (section[offset] << 8) | section[offset + 1];

    int descriptorsLoopLength = ((section[offset + 10] & 0x0f) << 8) | section[offset + 11];
    int descriptorOffset = offset + 12;
    int descriptorEnd = descriptorOffset + descriptorsLoopLength;
    if (descriptorEnd > eventsEnd) {
        return false;
    }

    while (descriptorOffset + 2 <= descriptorEnd) {
        int tag = section[descriptorOffset];
        int length = section[descriptorOffset + 1];
        int bodyOffset = descriptorOffset + 2;
        if (bodyOffset + length > descriptorEnd) {
            return false;
        }
        if (tag == DESCRIPTOR_TAG_EVENT_GROUP
            && parseEventGroupDescriptor(section + bodyOffset, length, source, candidate)) {
            return true;
        }
        descriptorOffset = bodyOffset + length;
    }
    return false;
}

int decodeBcd(uint8_t value)
{
    int high = (value >> 4) & 0x0f;
    int low = value & 0x0f;
    if (high > 9 || low > 9) {
        return -1;
    }
    return high * 10 + low;
}

void mjdToGregorian(int mjd, int *year, int *month, int *day)
{
    int j = mjd + 2400001 + 68569;
    int c = 4 * j / 146097;
    j = j - (146097 * c + 3) / 4;
    int y = 4000 * (j + 1) / 1461001;
    j = j - 1461 * y / 4 + 31;
    int m = 80 * j / 2447;
    int d = j - 2447 * m / 80;
    j = m / 11;
    m = m + 2 - 12 * j;
    y = 100 * (c - 49) + y + j;

    *year = y;
    *month = m;
    *day = d;
}

bool parseClockSection(
    const uint8_t *section,
    int sectionSize,
    int *year,
    int *month,
    int *day,
    int *hour,
    int *minute,
    int *second,
    std::string *table
)
{
    if (sectionSize < 8 || (section[0] != TABLE_ID_TDT && section[0] != TABLE_ID_TOT)) {
        return false;
    }

    int sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    if (sectionLength + 3 > sectionSize || sectionLength < 5) {
        return false;
    }

    int mjd = (section[3] << 8) | section[4];
    int parsedHour = decodeBcd(section[5]);
    int parsedMinute = decodeBcd(section[6]);
    int parsedSecond = decodeBcd(section[7]);
    if (parsedHour < 0 || parsedHour > 23
        || parsedMinute < 0 || parsedMinute > 59
        || parsedSecond < 0 || parsedSecond > 59) {
        return false;
    }

    mjdToGregorian(mjd, year, month, day);
    *hour = parsedHour;
    *minute = parsedMinute;
    *second = parsedSecond;
    *table = section[0] == TABLE_ID_TDT ? "tdt" : "tot";
    return true;
}

uint32_t mpegCrc32(const uint8_t *data, size_t size)
{
    uint32_t crc = 0xffffffff;
    for (size_t index = 0; index < size; ++index) {
        crc ^= static_cast<uint32_t>(data[index]) << 24;
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04c11db7 : (crc << 1);
        }
    }
    return crc;
}

bool containsPid(const std::vector<int> &pids, int pid)
{
    for (int item : pids) {
        if (item == pid) {
            return true;
        }
    }
    return false;
}

std::vector<uint8_t> buildSelectedPmtSection(
    const std::vector<uint8_t> &section,
    size_t sectionSize,
    const std::vector<int> &audioPids,
    int selectedAudioPid,
    int outputAudioPid
)
{
    if (sectionSize > section.size() || sectionSize < 16 || audioPids.size() < 2 || outputAudioPid < 0) {
        return std::vector<uint8_t>(section.begin(), section.begin() + sectionSize);
    }

    int sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    if (sectionLength + 3 > static_cast<int>(sectionSize) || sectionLength < 13) {
        return std::vector<uint8_t>(section.begin(), section.begin() + sectionSize);
    }

    int programInfoLength = ((section[10] & 0x0f) << 8) | section[11];
    int entriesOffset = 12 + programInfoLength;
    int entriesEnd = 3 + sectionLength - 4;
    if (entriesOffset > entriesEnd || entriesEnd > static_cast<int>(sectionSize)) {
        return std::vector<uint8_t>(section.begin(), section.begin() + sectionSize);
    }

    std::vector<uint8_t> output;
    output.insert(output.end(), section.begin(), section.begin() + entriesOffset);

    int offset = entriesOffset;
    while (offset + 5 <= entriesEnd) {
        int streamType = section[offset];
        int elementaryPid = ((section[offset + 1] & 0x1f) << 8) | section[offset + 2];
        int esInfoLength = ((section[offset + 3] & 0x0f) << 8) | section[offset + 4];
        int entryEnd = offset + 5 + esInfoLength;
        if (entryEnd > entriesEnd) {
            return std::vector<uint8_t>(section.begin(), section.begin() + sectionSize);
        }

        bool isAacAudio = streamType == STREAM_TYPE_AAC_ADTS && containsPid(audioPids, elementaryPid);
        if (!isAacAudio) {
            output.insert(output.end(), section.begin() + offset, section.begin() + entryEnd);
        } else if (elementaryPid == selectedAudioPid) {
            size_t entryOutputOffset = output.size();
            output.insert(output.end(), section.begin() + offset, section.begin() + entryEnd);
            output[entryOutputOffset + 1] = static_cast<uint8_t>((output[entryOutputOffset + 1] & 0xe0) | ((outputAudioPid >> 8) & 0x1f));
            output[entryOutputOffset + 2] = static_cast<uint8_t>(outputAudioPid & 0xff);
        }
        offset = entryEnd;
    }

    int newSectionLength = static_cast<int>(output.size() + 4 - 3);
    output[1] = static_cast<uint8_t>((output[1] & 0xf0) | ((newSectionLength >> 8) & 0x0f));
    output[2] = static_cast<uint8_t>(newSectionLength & 0xff);

    uint32_t crc = mpegCrc32(output.data(), output.size());
    output.push_back(static_cast<uint8_t>((crc >> 24) & 0xff));
    output.push_back(static_cast<uint8_t>((crc >> 16) & 0xff));
    output.push_back(static_cast<uint8_t>((crc >> 8) & 0xff));
    output.push_back(static_cast<uint8_t>(crc & 0xff));
    return output;
}

void writePsiSection(FILE *out, int pid, const std::vector<uint8_t> &section, int *counter)
{
    size_t offset = 0;
    bool first = true;
    while (offset < section.size()) {
        uint8_t packet[TS_PACKET_SIZE];
        std::memset(packet, 0xff, sizeof(packet));
        packet[0] = SYNC_BYTE;
        packet[1] = static_cast<uint8_t>(((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1f)));
        packet[2] = static_cast<uint8_t>(pid & 0xff);
        packet[3] = static_cast<uint8_t>(0x10 | (*counter & 0x0f));

        int payloadStart = 4;
        if (first) {
            packet[payloadStart++] = 0x00;
        }

        size_t payloadSize = TS_PACKET_SIZE - static_cast<size_t>(payloadStart);
        size_t remaining = section.size() - offset;
        if (payloadSize > remaining) {
            payloadSize = remaining;
        }
        std::memcpy(packet + payloadStart, section.data() + offset, payloadSize);
        writeAll(out, packet, sizeof(packet));

        *counter = (*counter + 1) & 0x0f;
        offset += payloadSize;
        first = false;
    }
    fflush(out);
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
    if (pes.size() < 9) {
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

    if (mode == AudioMode::Stereo) {
        if (!isDualMono) {
            aacWorkspace.clear();
        }
        return pes;
    }

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
        , forcedAudioPid_(forcedAudioPid >= 0)
        , muxSelectedToStereo_(muxSelectedToStereo)
        , lastMode_(currentMode())
    {
    }

    void processPacket(const uint8_t *packet, FILE *out)
    {
        int pid = pidOf(packet);
        int offset = payloadOffset(packet);
        updateSelectedAudioPid(out);

        if (pid == PID_PAT && offset >= 0) {
            PatProgramInfo info;
            if (parsePat(packet + offset, TS_PACKET_SIZE - offset, &info)
                && (pmtPid_ != info.pmtPid || serviceId_ != info.programNumber)) {
                pmtPid_ = info.pmtPid;
                serviceId_ = info.programNumber;
                pmtSection_.clear();
                pmtSectionExpectedSize_ = 0;
                eitSection_.clear();
                eitSectionExpectedSize_ = 0;
                lastRelayStatus_.clear();
                REPLAYCENTER_FILTER_DEBUG_LOG("[filter] service id=0x%x pmt pid=0x%x\n", serviceId_, pmtPid_);
            }
            writeAll(out, packet, TS_PACKET_SIZE);
            return;
        } else if (pid == PID_EIT && offset >= 0) {
            handleEitPacket(packet, offset);
            writeAll(out, packet, TS_PACKET_SIZE);
            return;
        } else if (pid == PID_TIME && offset >= 0) {
            handleClockPacket(packet, offset);
            writeAll(out, packet, TS_PACKET_SIZE);
            return;
        } else if (pid == pmtPid_ && offset >= 0) {
            std::vector<int> audioPids;
            if (payloadUnitStart(packet)) {
                pmtOutputCounter_ = continuityCounter(packet);
            }
            if (appendPsiSection(packet, offset, &pmtSection_, &pmtSectionExpectedSize_)
                && parsePmtSection(
                    pmtSection_.data(),
                    static_cast<int>(pmtSectionExpectedSize_),
                    &audioPids
                )) {
                if (audioPids_ != audioPids) {
                    audioPids_ = audioPids;
                    if (!forcedAudioPid_) {
                        int index = selectedAudioIndex(currentMode());
                        if (index >= static_cast<int>(audioPids_.size())) {
                            index = 0;
                        }
                        audioPid_ = audioPids_[index];
                    }
                    aacWorkspace_.clear();
                    isDualMono_ = false;
                    REPLAYCENTER_FILTER_DEBUG_LOG("[filter] audio pids=%s selected=0x%x\n", audioPidsLabel().c_str(), audioPid_);
                    emitAudioStatus();
                }
                writeSelectedPmt(out);
            }
            return;
        }

        if (!forcedAudioPid_ && audioPids_.empty()) {
            return;
        }

        if (pid == audioPid_) {
            audioWriter_.setInitialCounter(continuityCounter(packet));
            processAudioPacket(packet, offset, out);
            return;
        }

        if (isKnownAudioPid(pid)) {
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
        emitAudioStatus();
        audioWriter_.writePes(out, outputAudioPid(), transformed);
        currentPes_.clear();
    }

    void resetAacStateIfModeChanged(AudioMode mode)
    {
        if (mode == lastMode_) {
            return;
        }
        aacWorkspace_.clear();
        // Output mode changes do not alter the input AAC structure. Keep the
        // last confirmed classification so the UI does not briefly disable
        // dual-mono controls while the next frame is being reassembled.
        lastMode_ = mode;
        REPLAYCENTER_FILTER_DEBUG_LOG("[filter] audio mode state reset mode=%d\n", static_cast<int>(mode));
    }

    void updateSelectedAudioPid(FILE *out)
    {
        AudioMode mode = currentMode();
        if (mode == lastSelectionMode_) {
            return;
        }

        lastSelectionMode_ = mode;
        if (audioPids_.empty() || forcedAudioPid_) {
            emitAudioStatus();
            return;
        }

        int index = selectedAudioIndex(mode);
        if (index >= static_cast<int>(audioPids_.size())) {
            index = 0;
        }

        int selectedPid = audioPids_[index];
        if (audioPid_ == selectedPid) {
            emitAudioStatus();
            return;
        }

        audioPid_ = selectedPid;
        currentPes_.clear();
        aacWorkspace_.clear();
        isDualMono_ = false;
        REPLAYCENTER_FILTER_DEBUG_LOG("[filter] selected audio pid=0x%x mode=%d\n", audioPid_, static_cast<int>(mode));
        emitAudioStatus();
        writeSelectedPmt(out);
    }

    int selectedAudioIndex(AudioMode mode) const
    {
        switch (mode) {
        case AudioMode::Right:
            return 1;
        case AudioMode::Stereo:
        case AudioMode::Left:
            return 0;
        }
    }

    bool isKnownAudioPid(int pid) const
    {
        return containsPid(audioPids_, pid);
    }

    void handleClockPacket(const uint8_t *packet, int offset)
    {
        int year = 0;
        int month = 0;
        int day = 0;
        int hour = 0;
        int minute = 0;
        int second = 0;
        std::string table;
        if (!appendPsiSection(packet, offset, &clockSection_, &clockSectionExpectedSize_)
            || !parseClockSection(
                clockSection_.data(),
                static_cast<int>(clockSectionExpectedSize_),
                &year,
                &month,
                &day,
                &hour,
                &minute,
                &second,
                &table
            )) {
            return;
        }

        char value[32];
        std::snprintf(
            value,
            sizeof(value),
            "%04d-%02d-%02dT%02d:%02d:%02d",
            year,
            month,
            day,
            hour,
            minute,
            second
        );
        if (lastClockStatus_ == value) {
            return;
        }
        lastClockStatus_ = value;
        std::fprintf(
            stderr,
            "[filter-status] clock=%s table=%s\n",
            value,
            table.c_str()
        );
    }

    void handleEitPacket(const uint8_t *packet, int offset)
    {
        if (!appendPsiSection(packet, offset, &eitSection_, &eitSectionExpectedSize_)) {
            return;
        }
        if (eitSectionExpectedSize_ < 6
            || eitSection_[0] != TABLE_ID_EIT_PRESENT_FOLLOWING_ACTUAL
            || serviceId_ < 0) {
            return;
        }
        int sectionServiceId = (eitSection_[3] << 8) | eitSection_[4];
        if (sectionServiceId != serviceId_) {
            return;
        }

        EventRelayCandidate candidate;
        bool hasCandidate = parseEitSection(
            eitSection_.data(),
            static_cast<int>(eitSectionExpectedSize_),
            serviceId_,
            &candidate
        );
        if (hasCandidate) {
            relayMissCount_ = 0;
            emitRelayStatus(relayStatusLabel(candidate));
            return;
        }

        if (relayMissCount_ < EVENT_RELAY_CLEAR_MISS_THRESHOLD) {
            ++relayMissCount_;
        }
        if (relayMissCount_ >= EVENT_RELAY_CLEAR_MISS_THRESHOLD) {
            emitRelayStatus("none");
        }
    }

    void emitRelayStatus(const std::string &status)
    {
        if (status == lastRelayStatus_) {
            return;
        }
        lastRelayStatus_ = status;
        if (status == "none") {
            std::fprintf(stderr, "[filter-status] relay=none\n");
            return;
        }
        std::fprintf(stderr, "[filter-status] relay=event %s\n", status.c_str());
    }

    std::string relayStatusLabel(const EventRelayCandidate &candidate) const
    {
        char buffer[256];
        std::snprintf(
            buffer,
            sizeof(buffer),
            "group=0x%x sourceNid=0x%x sourceTsid=0x%x sourceSid=0x%x sourceEid=0x%x targetNid=0x%x targetTsid=0x%x targetSid=0x%x targetEid=0x%x",
            candidate.groupType,
            candidate.sourceNetworkId,
            candidate.sourceTransportStreamId,
            candidate.sourceServiceId,
            candidate.sourceEventId,
            candidate.targetNetworkId,
            candidate.targetTransportStreamId,
            candidate.targetServiceId,
            candidate.targetEventId
        );
        return buffer;
    }

    int outputAudioPid() const
    {
        if (audioPids_.size() >= 2 && !forcedAudioPid_) {
            return audioPids_[0];
        }
        return audioPid_;
    }

    void writeSelectedPmt(FILE *out)
    {
        if (pmtPid_ < 0 || pmtSection_.empty() || pmtSectionExpectedSize_ == 0) {
            return;
        }

        std::vector<uint8_t> selectedPmt = buildSelectedPmtSection(
            pmtSection_,
            pmtSectionExpectedSize_,
            audioPids_,
            audioPid_,
            outputAudioPid()
        );
        writePsiSection(out, pmtPid_, selectedPmt, &pmtOutputCounter_);
    }

    void logTransform(
        bool converted,
        const std::vector<uint8_t> &inputPes,
        const std::vector<uint8_t> &outputPes,
        AudioMode mode
    )
    {
#ifdef REPLAYCENTER_RELEASE_BUILD
        (void)converted;
        (void)inputPes;
        (void)outputPes;
        (void)mode;
        return;
#endif
        if (mode == AudioMode::Stereo) {
            return;
        }

        size_t inputFrames = countPesAdtsFrames(inputPes);
        size_t outputFrames = converted ? countPesAdtsFrames(outputPes) : inputFrames;

        if (converted) {
            ++convertedPesCount_;
            if (convertedPesCount_ <= 5 || convertedPesCount_ % 100 == 0) {
                REPLAYCENTER_FILTER_DEBUG_LOG(
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
                REPLAYCENTER_FILTER_DEBUG_LOG(
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

    void emitAudioStatus()
    {
        std::string state = audioStateLabel();
        if (state == lastAudioState_ && audioPids_ == lastStatusAudioPids_ && audioPid_ == lastStatusSelectedAudioPid_) {
            return;
        }

        lastAudioState_ = state;
        lastStatusAudioPids_ = audioPids_;
        lastStatusSelectedAudioPid_ = audioPid_;
        std::fprintf(
            stderr,
            "[filter-status] audioState=%s audioPids=%s selectedAudioPid=0x%x\n",
            state.c_str(),
            audioPidsLabel().c_str(),
            audioPid_
        );
    }

    std::string audioStateLabel() const
    {
        if (audioPids_.size() >= 2) {
            return "multiStream";
        }
        if (audioPids_.empty()) {
            return "unknown";
        }
        return isDualMono_ ? "dualMono" : "stereoSingle";
    }

    std::string audioPidsLabel() const
    {
        if (audioPids_.empty()) {
            return "-";
        }

        std::string label;
        char buffer[16];
        for (size_t index = 0; index < audioPids_.size(); ++index) {
            if (index > 0) {
                label += ",";
            }
            std::snprintf(buffer, sizeof(buffer), "0x%x", audioPids_[index]);
            label += buffer;
        }
        return label;
    }

    int pmtPid_ = -1;
    int serviceId_ = -1;
    int audioPid_ = -1;
    bool forcedAudioPid_ = false;
    std::vector<uint8_t> pmtSection_;
    size_t pmtSectionExpectedSize_ = 0;
    std::vector<uint8_t> eitSection_;
    size_t eitSectionExpectedSize_ = 0;
    std::vector<uint8_t> clockSection_;
    size_t clockSectionExpectedSize_ = 0;
    int pmtOutputCounter_ = 0;
    std::vector<int> audioPids_;
    std::vector<int> lastStatusAudioPids_;
    int lastStatusSelectedAudioPid_ = -1;
    std::string lastAudioState_;
    std::string lastClockStatus_;
    std::string lastRelayStatus_;
    int relayMissCount_ = EVENT_RELAY_CLEAR_MISS_THRESHOLD;
    bool muxSelectedToStereo_ = true;
    std::vector<uint8_t> currentPes_;
    std::vector<uint8_t> aacWorkspace_;
    TsWriter audioWriter_;
    bool isDualMono_ = false;
    AudioMode lastMode_;
    AudioMode lastSelectionMode_ = AudioMode::Stereo;
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

    REPLAYCENTER_FILTER_DEBUG_LOG(
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
