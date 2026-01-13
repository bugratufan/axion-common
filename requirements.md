# Axion Common - Functional Requirements

This document defines the functional requirements for the Axion Common VHDL library components.

## Document Information

| Field | Value |
|-------|-------|
| Version | 1.0 |
| Date | 2024-12-08 |
| Author | Bugra Tufan |
| Status | Active |

---

## 1. AXI4-Lite Protocol Requirements

These requirements define the AXI4-Lite protocol compliance for all AXI-related components.

### AXI-LITE-001: Write Address Channel Handshake

**Description:** The write address channel shall follow AXI4-Lite handshake protocol.

**Acceptance Criteria:**
- AWVALID shall be asserted by master when address is valid
- AWREADY shall be asserted by slave to accept address
- Transfer occurs when both AWVALID and AWREADY are high on rising clock edge
- AWADDR shall remain stable while AWVALID is high and AWREADY is low

**Test Method:** Verify handshake timing and signal stability during write address phase.

---

### AXI-LITE-002: Write Data Channel Handshake

**Description:** The write data channel shall follow AXI4-Lite handshake protocol.

**Acceptance Criteria:**
- WVALID shall be asserted by master when data is valid
- WREADY shall be asserted by slave to accept data
- Transfer occurs when both WVALID and WREADY are high on rising clock edge
- WDATA and WSTRB shall remain stable while WVALID is high and WREADY is low

**Test Method:** Verify handshake timing and signal stability during write data phase.

---

### AXI-LITE-003: Write Response Channel Handshake

**Description:** The write response channel shall follow AXI4-Lite handshake protocol.

**Acceptance Criteria:**
- BVALID shall be asserted by slave when response is valid
- BREADY shall be asserted by master to accept response
- Transfer occurs when both BVALID and BREADY are high on rising clock edge
- BRESP shall remain stable while BVALID is high and BREADY is low

**Test Method:** Verify handshake timing and signal stability during write response phase.

---

### AXI-LITE-004: Read Address Channel Handshake

**Description:** The read address channel shall follow AXI4-Lite handshake protocol.

**Acceptance Criteria:**
- ARVALID shall be asserted by master when address is valid
- ARREADY shall be asserted by slave to accept address
- Transfer occurs when both ARVALID and ARREADY are high on rising clock edge
- ARADDR shall remain stable while ARVALID is high and ARREADY is low

**Test Method:** Verify handshake timing and signal stability during read address phase.

---

### AXI-LITE-005: Read Data Channel Handshake

**Description:** The read data channel shall follow AXI4-Lite handshake protocol.

**Acceptance Criteria:**
- RVALID shall be asserted by slave when data is valid
- RREADY shall be asserted by master to accept data
- Transfer occurs when both RVALID and RREADY are high on rising clock edge
- RDATA and RRESP shall remain stable while RVALID is high and RREADY is low

**Test Method:** Verify handshake timing and signal stability during read data phase.

---

### AXI-LITE-006: OKAY Response Code

**Description:** A successful transaction shall return OKAY response (2'b00).

**Acceptance Criteria:**
- BRESP = 2'b00 for successful write transactions
- RRESP = 2'b00 for successful read transactions
- Response shall be generated after transaction completion

**Test Method:** Perform valid read/write transactions and verify OKAY response.

---

### AXI-LITE-007: SLVERR Response Code

**Description:** A slave error shall return SLVERR response (2'b10).

**Acceptance Criteria:**
- BRESP = 2'b10 when slave cannot complete write (e.g., invalid address)
- RRESP = 2'b10 when slave cannot complete read (e.g., invalid address)
- Error response shall be generated for undefined address ranges

**Test Method:** Perform transactions to invalid addresses and verify SLVERR response.

---

### AXI-LITE-008: Reset Behavior

**Description:** All outputs shall be in defined state after reset.

**Acceptance Criteria:**
- All VALID signals shall be deasserted (low) after reset
- All READY signals shall be in defined state after reset
- Response signals shall be in default state after reset
- State machine shall return to IDLE state after reset

**Test Method:** Apply reset and verify all signals are in expected state.

---

## 2. AXI-Lite Bridge Requirements

These requirements define the specific behavior of the `axion_axi_lite_bridge` component.

### AXION-COMMON-001: Request Broadcast

**Description:** The bridge shall forward incoming requests to all connected slave ports simultaneously.

**Acceptance Criteria:**
- Write address/data shall be forwarded to all G_NUM_SLAVES ports
- Read address shall be forwarded to all G_NUM_SLAVES ports
- All slaves shall receive the request within the same clock cycle
- Request signals shall be identical across all slave ports

**Test Method:** Monitor all slave port outputs during master request and verify simultaneous broadcast.

---

### AXION-COMMON-002: First OKAY Response Selection

**Description:** The bridge shall return the first OKAY response to the master.

**Acceptance Criteria:**
- When multiple slaves respond, first OKAY response shall be selected
- Response data from the OKAY-responding slave shall be forwarded to master
- Other responses shall be ignored after first OKAY is received
- Latency from slave response to master response shall be minimal (≤2 cycles)

**Test Method:** Configure multiple slaves to respond and verify first OKAY is returned.

---

### AXION-COMMON-003: All Error Response Handling

**Description:** When all slaves respond with error, the bridge shall return SLVERR to master.

**Acceptance Criteria:**
- If all G_NUM_SLAVES return SLVERR, bridge shall return SLVERR to master
- Bridge shall wait for all responses before returning error
- BRESP = 2'b10 for write transactions with all errors
- RRESP = 2'b10 for read transactions with all errors

**Test Method:** Configure all slaves to return SLVERR and verify bridge returns SLVERR.

---

### AXION-COMMON-004: Timeout Mechanism

**Description:** The bridge shall timeout if no response is received within configured time.

**Acceptance Criteria:**
- Timeout period shall be 2^G_TIMEOUT_WIDTH clock cycles
- If no slave responds within timeout, SLVERR shall be returned
- Timeout shall be configurable via G_TIMEOUT_WIDTH generic
- Timeout counter shall reset after each completed transaction

**Test Method:** Configure slaves to not respond and verify timeout with SLVERR response.

---

### AXION-COMMON-005: Generic Slave Count

**Description:** The bridge shall support configurable number of slave ports.

**Acceptance Criteria:**
- G_NUM_SLAVES generic shall define number of downstream slave ports
- Bridge shall function correctly with G_NUM_SLAVES = 1
- Bridge shall function correctly with G_NUM_SLAVES > 1 (e.g., 2, 4, 8)
- All slave ports shall be independent and functional

**Test Method:** Instantiate bridge with different G_NUM_SLAVES values and verify operation.

---

### AXION-COMMON-006: Write Transaction Sequence

**Description:** A complete write transaction shall follow the correct sequence.

**Acceptance Criteria:**
- Sequence: Address phase → Data phase → Response phase
- Master AWVALID accepted → Master WVALID accepted → Slave BVALID returned
- Bridge shall not accept new transaction until current is complete
- All phases shall complete before returning to IDLE

**Test Method:** Perform write transaction and verify correct phase sequence.

---

### AXION-COMMON-007: Read Transaction Sequence

**Description:** A complete read transaction shall follow the correct sequence.

**Acceptance Criteria:**
- Sequence: Address phase → Data/Response phase
- Master ARVALID accepted → Slave RVALID returned with data
- Bridge shall not accept new transaction until current is complete
- Read data shall be valid when RVALID is asserted

**Test Method:** Perform read transaction and verify correct phase sequence.

---

### AXION-COMMON-008: Back-to-Back Transactions

**Description:** The bridge shall support consecutive transactions without gaps.

**Acceptance Criteria:**
- New transaction can begin immediately after previous completes
- No minimum idle time required between transactions
- Both read and write transactions can be interleaved
- Bridge shall return to IDLE state between transactions

**Test Method:** Perform multiple consecutive transactions and verify no errors.

---

### AXION-COMMON-009: Partial Slave Response

**Description:** The bridge shall handle scenarios where only some slaves respond.

**Acceptance Criteria:**
- If at least one slave returns OKAY, bridge returns OKAY
- Remaining non-responding slaves are ignored after OKAY received
- If responding slaves all return error and others timeout, return SLVERR
- Response ordering shall not affect result

**Test Method:** Configure mixed response scenario and verify correct behavior.

---

### AXION-COMMON-010: Address Transparency

**Description:** The bridge shall pass addresses transparently to all slaves.

**Acceptance Criteria:**
- Full 32-bit address shall be forwarded to all slaves
- No address translation or masking shall occur
- AWADDR forwarded for write, ARADDR forwarded for read
- AWPROT and ARPROT shall also be forwarded

**Test Method:** Verify addresses on slave ports match master addresses exactly.

---

### AXION-COMMON-011: Data Integrity

**Description:** The bridge shall maintain data integrity for all transactions.

**Acceptance Criteria:**
- Write data (WDATA) shall be forwarded without modification
- Write strobes (WSTRB) shall be forwarded without modification
- Read data (RDATA) from slave shall be returned without modification
- No data corruption shall occur during transfer

**Test Method:** Verify data patterns are identical on input and output.

---

### AXION-COMMON-012: Reset Recovery

**Description:** The bridge shall recover correctly from reset during any state.

**Acceptance Criteria:**
- Reset during IDLE shall return to IDLE
- Reset during active transaction shall abort and return to IDLE
- No spurious responses shall be generated after reset
- All internal registers shall be cleared on reset

**Test Method:** Apply reset during various states and verify clean recovery.

---

## 3. Traceability Matrix

| Requirement ID | Component | Test Case |
|----------------|-----------|-----------|
| AXI-LITE-001 | axion_axi_lite_bridge | TC_AXI_WRITE_ADDR_HANDSHAKE |
| AXI-LITE-002 | axion_axi_lite_bridge | TC_AXI_WRITE_DATA_HANDSHAKE |
| AXI-LITE-003 | axion_axi_lite_bridge | TC_AXI_WRITE_RESP_HANDSHAKE |
| AXI-LITE-004 | axion_axi_lite_bridge | TC_AXI_READ_ADDR_HANDSHAKE |
| AXI-LITE-005 | axion_axi_lite_bridge | TC_AXI_READ_DATA_HANDSHAKE |
| AXI-LITE-006 | axion_axi_lite_bridge | TC_AXI_OKAY_RESPONSE |
| AXI-LITE-007 | axion_axi_lite_bridge | TC_AXI_SLVERR_RESPONSE |
| AXI-LITE-008 | axion_axi_lite_bridge | TC_AXI_RESET_BEHAVIOR |
| AXION-COMMON-001 | axion_axi_lite_bridge | TC_BRIDGE_REQUEST_BROADCAST |
| AXION-COMMON-002 | axion_axi_lite_bridge | TC_BRIDGE_FIRST_OKAY |
| AXION-COMMON-003 | axion_axi_lite_bridge | TC_BRIDGE_ALL_ERROR |
| AXION-COMMON-004 | axion_axi_lite_bridge | TC_BRIDGE_TIMEOUT |
| AXION-COMMON-005 | axion_axi_lite_bridge | TC_BRIDGE_SLAVE_COUNT |
| AXION-COMMON-006 | axion_axi_lite_bridge | TC_BRIDGE_WRITE_SEQUENCE |
| AXION-COMMON-007 | axion_axi_lite_bridge | TC_BRIDGE_READ_SEQUENCE |
| AXION-COMMON-008 | axion_axi_lite_bridge | TC_BRIDGE_BACK_TO_BACK |
| AXION-COMMON-009 | axion_axi_lite_bridge | TC_BRIDGE_PARTIAL_RESPONSE |
| AXION-COMMON-010 | axion_axi_lite_bridge | TC_BRIDGE_ADDR_TRANSPARENCY |
| AXION-COMMON-011 | axion_axi_lite_bridge | TC_BRIDGE_DATA_INTEGRITY |
| AXION-COMMON-012 | axion_axi_lite_bridge | TC_BRIDGE_RESET_RECOVERY |

---

## 4. Revision History

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2024-12-08 | Bugra Tufan | Initial release |
