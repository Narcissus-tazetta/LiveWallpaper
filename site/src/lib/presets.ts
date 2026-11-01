export type Vec3 = [number, number, number];

export interface Preset {
    id: string;
    stops: [Vec3, Vec3, Vec3, Vec3];
}

export const presets: Preset[] = [
    {
        id: "aurora",
        stops: [
            [0.02, 0.06, 0.14],
            [0.05, 0.45, 0.55],
            [0.18, 0.9, 0.65],
            [0.85, 1.0, 0.9],
        ],
    },
    {
        id: "dusk",
        stops: [
            [0.07, 0.03, 0.16],
            [0.45, 0.1, 0.5],
            [0.98, 0.4, 0.4],
            [1.0, 0.82, 0.55],
        ],
    },
    {
        id: "deep",
        stops: [
            [0.01, 0.04, 0.12],
            [0.04, 0.2, 0.55],
            [0.2, 0.5, 0.95],
            [0.75, 0.9, 1.0],
        ],
    },
];
