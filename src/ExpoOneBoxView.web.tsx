import * as React from 'react';

import { ExpoOneBoxViewProps } from './ExpoOneBox.types';

export default function ExpoOneBoxView(props: ExpoOneBoxViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
