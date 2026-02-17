import { requireNativeView } from 'expo';
import * as React from 'react';

import { ExpoOneBoxViewProps } from './ExpoOneBox.types';

const NativeView: React.ComponentType<ExpoOneBoxViewProps> =
  requireNativeView('ExpoOneBox');

export default function ExpoOneBoxView(props: ExpoOneBoxViewProps) {
  return <NativeView {...props} />;
}
