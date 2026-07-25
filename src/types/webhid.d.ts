/**
 * Minimal WebHID declarations.
 *
 * TypeScript's DOM lib does not ship WebHID types (it is not a W3C
 * Recommendation and Safari has not implemented it), so the surface this app
 * actually uses is declared here rather than pulling in a dependency for nine
 * interfaces.
 *
 * Kept deliberately narrow and read-only-leaning: `sendReport` and
 * `sendFeatureReport` are declared for completeness, but nothing in this app
 * calls them. Writing unverified byte sequences to a glasses MCU risks bricking
 * firmware, so the probe only ever enumerates and listens.
 *
 * Spec: https://wicg.github.io/webhid/
 */

interface HIDReportItem {
  isAbsolute?: boolean
  isArray?: boolean
  isBufferedBytes?: boolean
  isConstant?: boolean
  isLinear?: boolean
  isRange?: boolean
  isVolatile?: boolean
  hasNull?: boolean
  hasPreferredState?: boolean
  wrap?: boolean
  usages?: number[]
  usageMinimum?: number
  usageMaximum?: number
  /** Bits per field. */
  reportSize?: number
  /** Number of fields. */
  reportCount?: number
  unitExponent?: number
  unitFactorLengthExponent?: number
  unitFactorMassExponent?: number
  unitFactorTimeExponent?: number
  unitFactorTemperatureExponent?: number
  unitFactorCurrentExponent?: number
  unitFactorLuminousIntensityExponent?: number
  unitSystem?: string
  logicalMinimum?: number
  logicalMaximum?: number
  physicalMinimum?: number
  physicalMaximum?: number
  strings?: string[]
}

interface HIDReportInfo {
  reportId?: number
  items?: HIDReportItem[]
}

interface HIDCollectionInfo {
  usagePage?: number
  usage?: number
  type?: number
  children?: HIDCollectionInfo[]
  inputReports?: HIDReportInfo[]
  outputReports?: HIDReportInfo[]
  featureReports?: HIDReportInfo[]
}

interface HIDInputReportEvent extends Event {
  readonly device: HIDDevice
  readonly reportId: number
  readonly data: DataView
}

interface HIDDeviceEventMap {
  inputreport: HIDInputReportEvent
}

interface HIDDevice extends EventTarget {
  readonly opened: boolean
  readonly vendorId: number
  readonly productId: number
  readonly productName: string
  readonly collections: HIDCollectionInfo[]

  open(): Promise<void>
  close(): Promise<void>
  forget(): Promise<void>

  sendReport(reportId: number, data: BufferSource): Promise<void>
  sendFeatureReport(reportId: number, data: BufferSource): Promise<void>
  receiveFeatureReport(reportId: number): Promise<DataView>

  addEventListener<K extends keyof HIDDeviceEventMap>(
    type: K,
    listener: (this: HIDDevice, ev: HIDDeviceEventMap[K]) => void,
    options?: boolean | AddEventListenerOptions,
  ): void
  addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | AddEventListenerOptions,
  ): void

  removeEventListener<K extends keyof HIDDeviceEventMap>(
    type: K,
    listener: (this: HIDDevice, ev: HIDDeviceEventMap[K]) => void,
    options?: boolean | EventListenerOptions,
  ): void
  removeEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | EventListenerOptions,
  ): void
}

interface HIDDeviceFilter {
  vendorId?: number
  productId?: number
  usagePage?: number
  usage?: number
}

interface HIDDeviceRequestOptions {
  filters: HIDDeviceFilter[]
  exclusionFilters?: HIDDeviceFilter[]
}

interface HID extends EventTarget {
  getDevices(): Promise<HIDDevice[]>
  requestDevice(options: HIDDeviceRequestOptions): Promise<HIDDevice[]>
}

interface Navigator {
  readonly hid: HID
}
