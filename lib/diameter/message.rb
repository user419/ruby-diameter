require 'diameter/avp_parser'
require 'diameter/u24'

# A Diameter message.
#
# @!attribute [r] version
#   The Diameter protocol version (currently always 1)
# @!attribute [r] command_code
#   The Diameter Command-Code of this messsage.
# @!attribute [r] app_id
#   The Diameter application ID of this message, or 0 for base
#   protocol messages.
# @!attribute [r] hbh
#   The hop-by-hop identifier of this message.
# @!attribute [r] ete
#   The end-to-end identifier of this message.
# @!attribute [r] request
#   Whether this message is a request.
class DiameterMessage
  attr_reader :version, :command_code, :app_id, :hbh, :ete, :request

  # @!attribute [r] answer
  #   Whether this message is an answer.
  def answer
    !@request
  end

  # @option opts [Fixnum] command_code
  #   The Diameter Command-Code of this messsage.
  # @option opts [Fixnum] app_id
  #   The Diameter application ID of this message, or 0 for base
  #   protocol messages.
  # @option opts [Fixnum] hbh
  #   The hop-by-hop identifier of this message.
  # @option opts [Fixnum] ete
  #   The end-to-end identifier of this message.
  # @option opts [true, false] request
  #   Whether this message is a request. Defaults to true.
  # @option opts [true, false] proxyable
  #   Whether this message can be forwarded on. Defaults to true.
  # @option opts [true, false] error
  #   Whether this message is a Diameter protocol error. Defaults to false.
  # @option opts [Array<AVP>] avps
  #   The list of AVPs to include on this message.
  def initialize(options = {})
    @version = 1
    @command_code = options[:command_code]
    @app_id = options[:app_id]
    @hbh = options[:hbh] || DiameterMessage.next_hbh
    @ete = options[:ete] || DiameterMessage.next_ete

    @request = options.fetch(:request, true)
    @proxyable = options.fetch(:proxyable, false)
    @retransmitted = false
    @error = false

    @avps = options[:avps] || []
  end

  # Represents this message (and all its AVPs) in human-readable
  # string form.
  #
  # @see AVP::to_s for how the AVPs are represented.
  # @return [String]
  def to_s
    "#{@command_code}: #{@avps.collect(&:to_s)}"
  end

  # Serializes a Diameter message (header plus AVPs) into the series
  # of bytes representing it on the wire.
  #
  # @return [String] The byte-encoded form.
  def to_wire
    content = ''
    @avps.each { |a| content += a.to_wire }
    length_8, length_16 = UInt24.to_u8_and_u16(content.length + 20)
    code_8, code_16 = UInt24.to_u8_and_u16(@command_code)
    request_flag = @request ? '1' : '0'
    proxy_flag = @proxyable ? '1' : '0'
    flags_str = "#{request_flag}#{proxy_flag}000000"

    header = [@version, length_8, length_16, flags_str, code_8, code_16, @app_id, @hbh, @ete].pack('CCnB8CnNNN')
    header + content
  end

  # @!group AVP retrieval

  # Returns the first AVP with the given name. Only covers "top-level"
  # AVPs - it won't look inside Grouped AVPs.
  #
  # @param name [String] The AVP name, either one predefined in
  #   {AVPNames::AVAILABLE_AVPS} or user-defined with {AVP.define}
  #
  # @return [AVP] if there is an AVP with that name
  # @return [nil] if there is not an AVP with that name
  def avp_by_name(name)
    code, _type, vendor = AVPNames.get(name)
    avp_by_code(code, vendor)
  end

  # Returns all AVPs with the given name. Only covers "top-level"
  # AVPs - it won't look inside Grouped AVPs.
  #
  # @param name [String] The AVP name, either one predefined in
  #   {AVPNames::AVAILABLE_AVPS} or user-defined with {AVP.define}
  #
  # @return [Array<AVP>]
  def all_avps_by_name(name)
    code, _type, vendor = AVPNames.get(name)
    all_avps_by_code(code, vendor)
  end

  alias_method :avp, :avp_by_name
  alias_method :[], :all_avps_by_name
  
  # Returns the first AVP with the given code and vendor. Only covers "top-level"
  # AVPs - it won't look inside Grouped AVPs.
  #
  # @param code [Fixnum] The AVP Code
  # @param vendor [Fixnum] Optional vendor ID for a vendor-specific
  #   AVP.
  # @return [AVP] if there is an AVP with that code/vendor
  # @return [nil] if there is not an AVP with that code/vendor
  def avp_by_code(code, vendor = 0)
    avps = all_avps_by_code(code, vendor)
    if avps.empty?
      nil
    else
      avps[0]
    end
  end

  # Returns all AVPs with the given code and vendor. Only covers "top-level"
  # AVPs - it won't look inside Grouped AVPs.
  #
  # @param code [Fixnum] The AVP Code
  # @param vendor [Fixnum] Optional vendor ID for a vendor-specific
  #   AVP.
  # @return [Array<AVP>]
  def all_avps_by_code(code, vendor = 0)
    @avps.select do |a|
      vendor_match =
        if a.vendor_specific?
          a.vendor_id == vendor
        else
          vendor == 0
        end
      (a.code == code) && vendor_match
    end
  end

  # Does this message contain a (top-level) AVP with this name?
  # @param name [String] The AVP name, either one predefined in
  #   {AVPNames::AVAILABLE_AVPS} or user-defined with {AVP.define}
  #
  # @return [true, false]  
  def has_avp?(name)
    !!avp(name)
  end

  # @api private
  #
  # Adds an AVP to this message. Not recommended for normal use -
  # all AVPs should be given to the constructor. Used to allow the
  # stack to add appropriate Origin-Host/Origin-Realm AVPs to outbound
  # messages.
  # @param name [String] The AVP name, either one predefined in
  #   {AVPNames::AVAILABLE_AVPS} or user-defined with {AVP.define}
  # @param value [Object] The AVP value, with type dependent on the
  #   AVP itself.
  def add_avp(name, value)
    @avps << AVP.create(name, value)
  end
  
  # @!endgroup

  # @!group Parsing
  
  # Parses the first four bytes of the Diameter header to learn the
  # length. Callers should use this to work out how many more bytes
  # they need to read off a TCP connection to pass to self.from_bytes.
  #
  # @param header [String] A four-byte Diameter header
  # @return [Fixnum] The message length field from the header
  def self.length_from_header(header)
    _version, length_8, length_16 = header.unpack('CCn')
    UInt24.from_u8_and_u16(length_8, length_16)
  end

  # Parses a byte representation (a 20-byte header plus AVPs) into a
  # DiameterMessage object.
  #
  # @param bytes [String] The on-the-wire byte representation of a
  #   Diameter message.
  # @return [DiameterMessage] The parsed object form.
  def self.from_bytes(bytes)
    header = bytes[0..20]
    version, _length_8, _length_16, flags_str, code_8, code_16, app_id, hbh, ete = header.unpack('CCnB8CnNNN')
    command_code = UInt24.from_u8_and_u16(code_8, code_16)

    request = (flags_str[0] == '1')
    proxyable = (flags_str[1] == '1')

    avps = AVPParser.parse_avps_int(bytes[20..-1])
    DiameterMessage.new(version: version, command_code: command_code, app_id: app_id, hbh: hbh, ete: ete, request: request, proxyable: proxyable, retransmitted: false, error: false, avps: avps)
  end
  # @!endgroup

  # Generates an answer to this request, filling in a Result-Code or
  # Experimental-Result AVP.
  #
  # @param result_code [Fixnum] The value for the Result-Code AVP
  # @option opts [Fixnum] experimental_result_vendor
  #   If given, creates an Experimental-Result AVP with this vendor
  #   instead of the Result-Code AVP. 
  # @option opts [Array<String>] copying_avps
  #   A list of AVP names to copy from the request to the answer.
  # @option opts [Array<AVP>] avps
  #   A list of AVP objects to add on the answer.
  # @return [DiameterMessage] The response created.
  def create_answer(result_code, opts={})
    fail "Cannot answer an answer" if answer
    
    avps = opts.fetch(:avps, [])
    avps << if opts[:experimental_result_vendor]
              fail
            else
              AVP.create("Result-Code", result_code)
            end
    
    avps += opts.fetch(:copying_avps, []).collect do |name|
      src_avp = avp_by_name(name)

      fail if src_avp.nil?
  
      src_avp.dup
    end

    DiameterMessage.new(version: version, command_code: command_code, app_id: app_id, hbh: hbh, ete: ete, request: false, proxyable: @proxyable, retransmitted: false, error: false, avps: avps)
  end

  private
  def self.next_hbh
    @hbh ||= rand(10000)
    @hbh += 1
    @hbh
  end

  def self.next_ete
    @ete ||= (Time.now.to_i & 0x00000fff) + (rand(2**32) & 0xfffff000)
    @ete += 1
    @ete
  end

end
